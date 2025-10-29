#!/bin/bash
#=====================================================================
# recovery.sh
# Called automatically by Pgpool-II when a down node becomes available
# or when online recovery is triggered.
# This script identifies the current primary via PCP and resyncs
# the target standby (old node) using resync.sh.
#=====================================================================

set -euo pipefail

#change this as per ur required path 
NODE_ID="${1:-}"
LOG=/var/log/pgpool/recovery.log
mkdir -p /var/log/pgpool
exec >>"$LOG" 2>&1

echo "=====================================================================" 
echo "$(date '+%F %T') [INFO] recovery.sh called with NODE_ID=$NODE_ID"

# --- Mapping Node IDs to ports and data directories -----------------
case "$NODE_ID" in
  0)
    TARGET_PGDATA="/var/lib/postgresql/18/main"
    TARGET_PORT=5432
    TARGET_HOST="localhost"
    ;;
  1)
    TARGET_PGDATA="/var/lib/postgresql/18/standby1"
    TARGET_PORT=5433
    TARGET_HOST="localhost"
    ;;
  2)
    TARGET_PGDATA="/var/lib/postgresql/18/standby2"
    TARGET_PORT=5434
    TARGET_HOST="localhost"
    ;;
  *)
    echo "$(date '+%F %T') [ERROR] Unknown node id: $NODE_ID"
    exit 1
    ;;
esac

echo "$(date '+%F %T') [INFO] Target node: $TARGET_HOST:$TARGET_PORT ($TARGET_PGDATA)"

# --- PCP settings ---------------------------------------------------
PCP_PORT=9898
PCP_USER=postgres

# --- Detect current primary using pcp_node_info ---------------------
echo "$(date '+%F %T') [INFO] Detecting current primary node..."
#PRIMARY_INFO=$(sudo -u postgres pcp_node_info -h localhost -U "$PCP_USER" -p "$PCP_PORT" 2>/dev/null | grep "primary primary" | head -n 1)
# Detect current primary node
PRIMARY_INFO=$(sudo -u postgres pcp_node_info -h localhost -U "$PCP_USER" -p "$PCP_PORT" 2>/dev/null \
  | awk '$7=="primary" {print $1 ":" $2; exit}')

if [ -z "$PRIMARY_INFO" ]; then
  echo "$(date '+%F %T') [ERROR] Could not determine primary via pcp_node_info"
  exit 1
fi

# --- Split host:port correctly ---
PRIMARY_HOST=${PRIMARY_INFO%%:*}   # everything before colon
PRIMARY_PORT=${PRIMARY_INFO##*:}   # everything after colon

echo "$(date '+%F %T') [INFO] Current primary detected: $PRIMARY_HOST:$PRIMARY_PORT"

# --- Safety check: do not resync the current primary ---
if [ "$PRIMARY_PORT" = "$TARGET_PORT" ]; then
  echo "$(date '+%F %T') [WARN] Target node is already primary; skipping resync."
  exit 0
fi

# --- Perform the resync ---
echo "$(date '+%F %T') [INFO] Calling resync.sh for node $NODE_ID..."
/etc/pgpool2/resync.sh "$TARGET_HOST" "$PRIMARY_HOST" "$TARGET_PORT" "$PRIMARY_PORT" "$TARGET_PGDATA" >> /var/log/pgpool/resync.log 2>&1

RC=$?
if [ $RC -eq 0 ]; then
  echo "$(date '+%F %T') [INFO] Recovery completed successfully for node $NODE_ID."
else
  echo "$(date '+%F %T') [ERROR] Recovery failed for node $NODE_ID (exit=$RC). Check resync.log."
fi


echo "====================================================================="
exit $RC
