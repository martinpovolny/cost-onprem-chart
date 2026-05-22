#!/usr/bin/env bash
# Wait for CRC to reach OpenShift: Running on foobar.
# Recreates the CRC instance only when there has been no progress for 15 minutes.
# Progress is measured by changes in RAM usage, Disk usage, or OpenShift status.
#
# Usage:
#   ./scripts/util/wait-for-crc.sh
#
# On success (CRC ready) exits 0.  Loops indefinitely, recreating as needed.

set -euo pipefail

REMOTE="martin@192.168.77.5"
SSH="ssh -o ConnectTimeout=10 $REMOTE"
STALL_SECONDS=900  # 15 minutes without any change → recreate

last_change=$SECONDS
last_snapshot=""

while true; do
  out=$($SSH "~/bin/crc status 2>&1") || true
  snapshot=$(echo "$out" | grep -E "OpenShift:|RAM Usage:|Disk Usage:" | tr '\n' '|')
  echo "$(date '+%H:%M:%S')  $snapshot"

  if echo "$snapshot" | grep -q "OpenShift:.*Running"; then
    echo "CRC ready"
    exit 0
  fi

  if [ "$snapshot" != "$last_snapshot" ]; then
    last_change=$SECONDS
    last_snapshot="$snapshot"
  fi

  idle=$(( SECONDS - last_change ))
  if [ $idle -ge $STALL_SECONDS ]; then
    echo "No progress for 15 min — recreating CRC"
    $SSH "~/bin/crc stop --force 2>&1; ~/bin/crc delete --force 2>&1; nohup ~/bin/crc start -p ~/.crc-secret.json > /tmp/crc-start.log 2>&1 &" || true
    last_change=$SECONDS
    last_snapshot=""
  fi

  sleep 30
done
