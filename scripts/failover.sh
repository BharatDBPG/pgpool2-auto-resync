#!/bin/bash
# failover.sh — Pgpool-II failover handling script
# Args: %d %h %p %D %m %H %M %P

FAILED_NODE_ID="$1"
FAILED_HOST="$2"
FAILED_PORT="$3"
FAILED_DATA="$4"
NEW_PRIMARY_NODE_ID="$5"
NEW_PRIMARY_HOST="$6"
NEW_PRIMARY_PORT="$7"

#change this as per your requirement 
PG_BIN="/usr/lib/postgresql/18/bin"
PGDATA="/var/lib/postgresql/18/main"
LOG="/var/log/pgpool/failover.log"

mkdir -p /var/log/pgpool
echo "$(date '+%F %T') Failover triggered: failed_node=$FAILED_NODE_ID host=$FAILED_HOST:$FAILED_PORT new_primary=$NEW_PRIMARY_HOST:$NEW_PRIMARY_PORT" >> "$LOG"

# 1️⃣ If the failed node was the old primary
if [ "$FAILED_NODE_ID" != "$NEW_PRIMARY_NODE_ID" ]; then
    echo "$(date '+%F %T') Promoting new primary at $NEW_PRIMARY_HOST:$NEW_PRIMARY_PORT..." >> "$LOG"
    sudo -u postgres "$PG_BIN/pg_ctl" promote -D "$PGDATA" >> "$LOG" 2>&1
    echo "$(date '+%F %T') Promotion completed for node_id=$NEW_PRIMARY_NODE_ID" >> "$LOG"
else
    echo "$(date '+%F %T') Standby node $FAILED_HOST:$FAILED_PORT failed. No promotion required." >> "$LOG"
fi

exit 0
