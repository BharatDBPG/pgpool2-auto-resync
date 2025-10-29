#!/bin/bash
# follow_primary.sh
# Called by Pgpool-II after a new primary is elected.
# Args: %d (failed node id)
#       %h (failed host)
#       %p (failed port)
#       %D (failed data directory)
#       %m (new primary node id)
#       %H (new primary host)
#       %M (new primary port)

FAILED_ID="$1"
FAILED_HOST="$2"
FAILED_PORT="$3"
FAILED_DATA="$4"
NEW_MAIN_ID="$5"
NEW_MAIN_HOST="$6"
NEW_MAIN_PORT="$7"

LOG="/var/log/pgpool/follow_primary.log"
mkdir -p /var/log/pgpool

echo "$(date '+%F %T') follow_primary: failed=$FAILED_HOST:$FAILED_PORT new_primary=$NEW_MAIN_HOST:$NEW_MAIN_PORT" >> "$LOG"

# Path to your resync script (this handles recloning/resyncing)
RESYNC_SCRIPT="/etc/pgpool2/resync.sh"

if [ -x "$RESYNC_SCRIPT" ]; then
    echo "$(date '+%F %T') Starting resync of old primary ($FAILED_HOST:$FAILED_PORT) from new primary ($NEW_MAIN_HOST:$NEW_MAIN_PORT)..." >> "$LOG"
    "$RESYNC_SCRIPT" "$FAILED_HOST" "$NEW_MAIN_HOST" "$FAILED_PORT" "$NEW_MAIN_PORT" "$FAILED_DATA" >> "$LOG" 2>&1 &
    echo "$(date '+%F %T') Resync script triggered successfully." >> "$LOG"
else
    echo "$(date '+%F %T') ERROR: Resync script not found or not executable at $RESYNC_SCRIPT" >> "$LOG"
fi

exit 0
