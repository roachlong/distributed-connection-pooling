#!/bin/bash
# Install automatic /dev/shm cleanup on all HA nodes
set -euo pipefail

REGIONS=("us-east" "us-west" "us-central")
NODES_PER_REGION=2

echo "=== Installing /dev/shm cleanup on all HA nodes ==="

for region in "${REGIONS[@]}"; do
  for idx in $(seq 1 $NODES_PER_REGION); do
    NODE="ha-node-${region}-${idx}"

    echo "→ Installing on ${NODE}"

    # Copy cleanup script
    docker cp cleanup-shm.sh "${NODE}:/usr/local/bin/cleanup-shm.sh"
    docker exec "${NODE}" chmod +x /usr/local/bin/cleanup-shm.sh

    # Create systemd service
    docker exec "${NODE}" bash -c 'cat > /etc/systemd/system/cleanup-shm.service <<EOF
[Unit]
Description=Cleanup stale Pacemaker IPC files from /dev/shm
After=pacemaker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cleanup-shm.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF'

    # Create systemd timer (runs every 15 minutes)
    docker exec "${NODE}" bash -c 'cat > /etc/systemd/system/cleanup-shm.timer <<EOF
[Unit]
Description=Periodic cleanup of /dev/shm
Requires=cleanup-shm.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF'

    # Enable and start the timer
    docker exec "${NODE}" bash -c '
      systemctl daemon-reload
      systemctl enable --now cleanup-shm.timer
      systemctl status cleanup-shm.timer --no-pager | head -5
    '

    echo "  ✓ ${NODE} configured"
  done
done

echo
echo "=== Cleanup timers installed ==="
echo "The cleanup script runs:"
echo "  - 5 minutes after boot"
echo "  - Every 15 minutes thereafter"
echo
echo "To manually trigger cleanup on a node:"
echo "  docker exec ha-node-us-east-1 systemctl start cleanup-shm.service"
echo
echo "To check timer status:"
echo "  docker exec ha-node-us-east-1 systemctl status cleanup-shm.timer"
