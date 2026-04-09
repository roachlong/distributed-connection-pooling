# HA Node Setup

This directory contains the Docker setup for high-availability nodes using Pacemaker, Corosync, and HAProxy.

## Quick Start (Docker Compose)

### 1. Start the containers

```bash
cd ha-node
docker-compose up -d
```

This creates 6 containers (2 nodes per region × 3 regions):
- `ha-node-us-east-1` and `ha-node-us-east-2`
- `ha-node-us-west-1` and `ha-node-us-west-2`
- `ha-node-us-central-1` and `ha-node-us-central-2`

**Key improvements over manual setup:**
- ✅ `shm_size: 256m` - Prevents `/dev/shm` exhaustion (fixes "No space left on device" errors)
- ✅ All containers configured consistently
- ✅ Easy to tear down and restart: `docker-compose down && docker-compose up -d`

### 2. Initialize the HA clusters

```bash
./init-ha-cluster.sh
```

This automates steps 2-6 from the main README:
- Waits for systemd to start
- Enables `pcsd` and sets `hacluster` password
- Configures `/etc/hosts` for node resolution
- Generates Corosync authkeys
- Creates `corosync.conf` with UDPU transport
- Starts Corosync and Pacemaker
- Sets basic Pacemaker properties

### 3. Continue with manual steps (VIP, HAProxy, etc.)

After initialization completes, follow steps 7-12 from the main README to:
- Create virtual IPs (VIPs)
- Configure HAProxy
- Set up Pacemaker resource constraints
- Test failover
- Enable fencing (optional)

## Teardown

```bash
# Stop and remove containers
docker-compose down

# Or just stop without removing
docker-compose stop

# Restart existing containers
docker-compose start
```

## Troubleshooting

### Check systemd status
```bash
docker exec ha-node-us-east-1 systemctl is-system-running
```

### Check Pacemaker status
```bash
docker exec ha-node-us-east-1 pcs status
```

### Check Corosync ring
```bash
docker exec ha-node-us-east-1 corosync-cfgtool -s
```

### Check logs
```bash
docker exec ha-node-us-east-1 journalctl -u pacemaker -n 50
docker exec ha-node-us-east-1 tail -n 50 /var/log/corosync/corosync.log
```

### Clean /dev/shm if needed
```bash
docker exec ha-node-us-east-1 bash -c "systemctl stop pacemaker && rm -rf /dev/shm/qb-* && systemctl start pacemaker"
```

## Why Docker Compose?

The original manual setup works but has issues:
1. **Disk space errors**: Default Docker `shm_size` of 64MB causes Pacemaker IPC failures
2. **Manual repetition**: Same `docker run` command repeated 6 times with different names
3. **Hard to maintain**: Flags scattered across shell scripts
4. **Difficult teardown**: Must manually stop/rm each container

Docker Compose fixes all of this while still supporting the same functionality.
