# HA Node Troubleshooting

## Common Issues

### 1. `/dev/shm` filling up with stale IPC files

**Symptoms:**
- Pacemaker crashes with `status=100`
- `pcs` commands fail with "Connection refused" or "unable to get cib"
- `/dev/shm` usage > 80%

**Root Cause:**
Pacemaker/Corosync create IPC files (named `qb-*`) in `/dev/shm`. When processes crash, these files aren't cleaned up automatically.

**Prevention Strategies:**

#### Option 1: Automatic Cleanup (RECOMMENDED)

Install the systemd timer that cleans up stale files every 15 minutes:

```bash
cd ha-node
./install-shm-cleanup.sh
```

This adds:
- `/usr/local/bin/cleanup-shm.sh` - Cleanup script
- `cleanup-shm.service` - Systemd service
- `cleanup-shm.timer` - Runs every 15 minutes

**Verify it's working:**
```bash
docker exec ha-node-us-east-1 systemctl status cleanup-shm.timer
docker exec ha-node-us-east-1 journalctl -u cleanup-shm.service -n 20
```

#### Option 2: Increase shm_size

We've set `shm_size: 512m` in docker-compose.yml (up from Docker's 64m default). If you still see issues:

1. Edit `docker-compose.yml` and increase to `1024m` (1GB)
2. Recreate containers: `docker-compose down && docker-compose up -d`

**Check current usage:**
```bash
for region in us-east us-west us-central; do
  echo "=== ${region}-1 ==="
  docker exec ha-node-${region}-1 df -h /dev/shm
done
```

#### Option 3: Manual Cleanup (Emergency)

If clusters are broken and you need immediate recovery:

```bash
# Clean all nodes
for region in us-east us-west us-central; do
  for idx in 1 2; do
    docker exec ha-node-${region}-${idx} bash -c "
      systemctl stop pacemaker corosync
      rm -rf /dev/shm/qb-*
      systemctl start corosync pacemaker
    "
  done
done

# Wait for clusters to stabilize
sleep 10

# Check status
for region in us-east us-west us-central; do
  docker exec ha-node-${region}-1 pcs status
done
```

#### Option 4: Tune Pacemaker IPC Settings

Reduce IPC buffer sizes to use less shared memory. Add to Corosync config:

```bash
# Edit corosync.conf on all nodes
docker exec ha-node-us-east-1 bash -c "cat >> /etc/corosync/corosync.conf <<'EOF'

# Reduce IPC buffer sizes
qb {
    ipc_needs = trysharedmem
}
EOF"

# Restart corosync
docker exec ha-node-us-east-1 systemctl restart corosync pacemaker
```

---

### 2. VIPs stuck in "Stopped" state

**Symptoms:**
```
  * vip-us-east (ocf:heartbeat:IPaddr2):    Stopped
```

**Diagnosis:**

```bash
# Check resource status
docker exec ha-node-us-east-1 pcs status resources

# Try to debug-start the VIP
docker exec ha-node-us-east-1 pcs resource debug-start vip-us-east

# Check Pacemaker logs
docker exec ha-node-us-east-1 journalctl -u pacemaker -n 50
```

**Common causes:**

1. **Pacemaker crashed** - See `/dev/shm` issue above
2. **Resource constraints** - VIP waiting for HAProxy to stop first
3. **Network issues** - IP already in use or NIC not available

**Fix:**

```bash
# Clear any constraints
docker exec ha-node-us-east-1 pcs constraint --full

# Try to enable/start the resource
docker exec ha-node-us-east-1 pcs resource enable vip-us-east
docker exec ha-node-us-east-1 pcs resource cleanup vip-us-east

# If still stuck, remove and recreate
docker exec ha-node-us-east-1 pcs resource delete vip-us-east
docker exec ha-node-us-east-1 pcs resource create vip-us-east ocf:heartbeat:IPaddr2 \
  ip=172.18.0.251 cidr_netmask=24 nic=eth0 op monitor interval=30s
```

---

### 3. "No route to host" when connecting to VIP

**Cause:** VIP is not actually assigned to any node interface.

**Verify VIP is up:**

```bash
VIP=172.18.0.251  # us-east

# Check which node has the VIP
docker exec ha-node-us-east-1 ip addr show eth0 | grep $VIP || echo "VIP not on node 1"
docker exec ha-node-us-east-2 ip addr show eth0 | grep $VIP || echo "VIP not on node 2"

# Check Pacemaker resource status
docker exec ha-node-us-east-1 pcs status resources
```

**If VIP is Stopped:** See section 2 above.

---

### 4. Corosync ring failures

**Symptoms:**
```
corosync-cfgtool -s
# Shows: FAULTY
```

**Check:**
```bash
docker exec ha-node-us-east-1 corosync-cfgtool -s
docker exec ha-node-us-east-1 tail -n 100 /var/log/corosync/corosync.log
```

**Common fixes:**

1. **Restart Corosync:**
   ```bash
   docker exec ha-node-us-east-1 systemctl restart corosync
   ```

2. **Check node resolution:**
   ```bash
   docker exec ha-node-us-east-1 getent hosts ha-node-us-east-1
   docker exec ha-node-us-east-1 getent hosts ha-node-us-east-2
   ```

3. **Verify IPs in corosync.conf match actual IPs:**
   ```bash
   docker exec ha-node-us-east-1 cat /etc/corosync/corosync.conf | grep ring0_addr
   docker exec ha-node-us-east-1 ip addr show eth0
   ```

---

### 5. HAProxy not serving traffic

**Check HAProxy status:**
```bash
docker exec ha-node-us-east-1 systemctl status haproxy
docker exec ha-node-us-east-1 curl localhost:8404/stats
```

**Check backend health:**
```bash
docker exec ha-node-us-east-1 curl localhost:8404/stats | grep pgb
```

**Common issues:**

1. **PgBouncer containers not running**
2. **DNS resolution failing** (PgBouncer container names not resolving)
3. **Wrong network** (HAProxy can't reach PgBouncer containers)

**Fix:**
```bash
# Verify PgBouncer containers are on dcp-net
docker ps --filter "name=pgbouncer" --format "table {{.Names}}\t{{.Networks}}"

# Test name resolution from HA node
docker exec ha-node-us-east-1 getent hosts pgbouncer-us-east-1

# Test connectivity
docker exec ha-node-us-east-1 nc -zv pgbouncer-us-east-1 5432
```

---

## Monitoring Commands

### Quick health check
```bash
# Check all clusters
for region in us-east us-west us-central; do
  echo "=== ${region} ==="
  docker exec ha-node-${region}-1 pcs status --full 2>&1 | head -20
  echo
done
```

### Check /dev/shm usage on all nodes
```bash
for region in us-east us-west us-central; do
  for idx in 1 2; do
    echo -n "ha-node-${region}-${idx}: "
    docker exec ha-node-${region}-${idx} df -h /dev/shm | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}'
  done
done
```

### Count stale IPC files
```bash
docker exec ha-node-us-east-1 bash -c '
  echo "Total qb-* directories: $(find /dev/shm -maxdepth 1 -name "qb-*" -type d | wc -l)"
  echo "Stale (>1 hour old): $(find /dev/shm -maxdepth 1 -name "qb-*" -type d -mmin +60 | wc -l)"
'
```

### Watch Pacemaker logs
```bash
docker exec ha-node-us-east-1 journalctl -u pacemaker -f
```
