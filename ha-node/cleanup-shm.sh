#!/bin/bash
# Cleanup stale Pacemaker/Corosync IPC files from /dev/shm
# These accumulate when processes crash without proper cleanup

set -eo pipefail

SHM_DIR="/dev/shm"
MAX_AGE_MINUTES=60  # Remove IPC directories older than 60 minutes

echo "[$(date)] Starting /dev/shm cleanup"

# Find stale qb-* directories
STALE_COUNT=0
while IFS= read -r -d '' dir; do
  if [[ -d "$dir" ]]; then
    # Check if the process that created it still exists
    # qb directories are named qb-PID-*
    PID=$(basename "$dir" | cut -d'-' -f2)

    if ! kill -0 "$PID" 2>/dev/null; then
      # Process doesn't exist, safe to remove
      echo "  Removing stale IPC dir: $(basename "$dir") (PID $PID not running)"
      rm -rf "$dir"
      ((STALE_COUNT++))
    fi
  fi
done < <(find "$SHM_DIR" -maxdepth 1 -type d -name "qb-*" -mmin +$MAX_AGE_MINUTES -print0)

# Also clean up any files older than MAX_AGE_MINUTES
OLD_FILES=$(find "$SHM_DIR" -maxdepth 1 -type f -mmin +$MAX_AGE_MINUTES -name "qb-*" 2>/dev/null | wc -l)
if [[ $OLD_FILES -gt 0 ]]; then
  find "$SHM_DIR" -maxdepth 1 -type f -mmin +$MAX_AGE_MINUTES -name "qb-*" -delete
  echo "  Removed $OLD_FILES stale IPC files"
fi

USAGE=$(df -h "$SHM_DIR" | tail -1 | awk '{print $5}')
echo "[$(date)] Cleanup complete. Removed $STALE_COUNT stale directories. /dev/shm usage: $USAGE"
