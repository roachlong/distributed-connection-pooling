#!/bin/bash
set -euo pipefail

REGIONS=("us-east" "us-west" "us-central")
NODES_PER_REGION=2

echo "=== Multi-Region HA Cluster Initialization ==="
echo "This script automates the 12-step HA setup process"
echo

# Step 1: Verify containers are running
echo "=== Step 1: Verifying containers ==="
for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do
    NAME="ha-node-${region}-${idx}"
    if ! docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
      echo "ERROR: Container ${NAME} is not running"
      echo "Run: cd ha-node && docker-compose up -d"
      exit 1
    fi
  done
done
echo "✓ All containers running"
echo

# Step 2: Wait for systemd
echo "=== Step 2: Waiting for systemd in all nodes ==="
for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do
    docker exec "ha-node-${region}-${idx}" bash -lc 'systemctl is-system-running --wait || true' >/dev/null
    echo "✓ ha-node-${region}-${idx}"
  done
done
echo

# Step 3: Enable pcsd and set hacluster password
echo "=== Step 3: Enabling pcsd and setting hacluster password ==="
for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do
    docker exec "ha-node-${region}-${idx}" bash -lc '
      systemctl enable --now pcsd >/dev/null 2>&1 &&
      echo -e "secret\nsecret" | passwd hacluster >/dev/null 2>&1
    '
    echo "✓ ha-node-${region}-${idx}"
  done
done
echo

# Step 4: Get IPs and configure /etc/hosts
echo "=== Step 4: Configuring node resolution ==="
declare -A HA_NODE_IP
declare -A REGION_HOST_LINES

# Collect all IPs
for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"
    IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NODE")
    HA_NODE_IP["$region-$idx"]="$IP"
    echo "  $NODE → $IP"
  done
done

# Build host lines per region
for region in "${REGIONS[@]}"; do
  LINES=""
  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"
    IP="${HA_NODE_IP["$region-$idx"]}"
    LINES+="${IP} ${NODE}"$'\n'
  done
  REGION_HOST_LINES["$region"]="$LINES"
done

# Update /etc/hosts in each region
for region in "${REGIONS[@]}"; do
  HOST_LINES="${REGION_HOST_LINES["$region"]}"

  for idx in $(seq 1 "$NODES_PER_REGION"); do
    NODE="ha-node-${region}-${idx}"
    docker exec "$NODE" bash -c "
      cp /etc/hosts /etc/hosts.bak
      awk '!/ha-node-${region}/' /etc/hosts > /tmp/hosts
      printf '%s' '$HOST_LINES' | cat - /tmp/hosts > /etc/hosts
    " >/dev/null
  done
  echo "✓ ${region} hosts configured"
done
echo

# Step 5: Configure Corosync per region
echo "=== Step 5: Configuring Corosync (UDPU) ==="
for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"
  NODE2="ha-node-${region}-2"

  IP1="${HA_NODE_IP["${region}-1"]}"
  IP2="${HA_NODE_IP["${region}-2"]}"

  # Generate authkey on seed node
  docker exec "$SEED_NODE" bash -lc 'corosync-keygen -l' >/dev/null 2>&1

  # Copy authkey to second node
  KEY64=$(docker exec "$SEED_NODE" bash -lc "base64 -w0 /etc/corosync/authkey")
  docker exec "$NODE2" bash -lc "echo '$KEY64' | base64 -d > /etc/corosync/authkey && chmod 400 /etc/corosync/authkey"

  # Generate corosync.conf
  CONF=$(cat <<EOF
totem {
    version: 2
    cluster_name: ha-cluster-${region}
    transport: knet
    token: 5000
    token_retransmits_before_loss_const: 10
    join: 60
    max_messages: 20
    secauth: on
    crypto_cipher: aes256
    crypto_hash: sha256
}

nodelist {
    node {
        nodeid: 1
        name: ${SEED_NODE}
        ring0_addr: ${IP1}
    }
    node {
        nodeid: 2
        name: ${NODE2}
        ring0_addr: ${IP2}
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    wait_for_all: 1
    auto_tie_breaker: 1
    last_man_standing: 1
}

logging {
    to_stderr: no
    to_logfile: yes
    logfile: /var/log/corosync/corosync.log
    to_syslog: yes
    debug: off
    timestamp: on
}
EOF
)

  # Write config to both nodes
  echo "$CONF" | docker exec -i "$SEED_NODE" bash -c 'cat > /etc/corosync/corosync.conf'
  echo "$CONF" | docker exec -i "$NODE2" bash -c 'cat > /etc/corosync/corosync.conf'

  # Configure systemd override and start services
  for node in "$SEED_NODE" "$NODE2"; do
    docker exec "$node" bash -lc '
      mkdir -p /etc/systemd/system/corosync.service.d
      cat > /etc/systemd/system/corosync.service.d/override.conf <<OVERRIDE
[Service]
ExecStart=
ExecStart=/usr/sbin/corosync -f -c /etc/corosync/corosync.conf
EnvironmentFile=
OVERRIDE
      systemctl daemon-reload
      systemctl restart corosync
      systemctl enable --now corosync pacemaker
    ' >/dev/null 2>&1
  done

  echo "✓ ${region} cluster configured"
done

# Wait for clusters to stabilize
echo "  Waiting 10s for clusters to stabilize..."
sleep 10
echo

# Step 6: Bootstrap Pacemaker properties
echo "=== Step 6: Setting Pacemaker properties ==="
for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"

  docker exec "$SEED_NODE" bash -lc '
    pcs property set stonith-enabled=false >/dev/null 2>&1
    pcs property set no-quorum-policy=ignore >/dev/null 2>&1
  '
  echo "✓ ${region} properties set"
done
echo

# Verify cluster status
echo "=== Verifying cluster status ==="
for region in "${REGIONS[@]}"; do
  SEED_NODE="ha-node-${region}-1"
  echo "--- ${region} ---"
  docker exec "$SEED_NODE" pcs status | head -15
  echo
done

echo "=========================================="
echo "✓ HA Cluster initialization complete!"
echo "=========================================="
echo
echo "Next steps:"
echo "  7. Create VIPs (one per region)"
echo "  8. Configure HAProxy"
echo "  9. Create Pacemaker resources for HAProxy"
echo " 10. Test failover"
echo " 11. Enable fencing (optional for demo)"
echo
echo "See README.md for detailed instructions on these steps."
