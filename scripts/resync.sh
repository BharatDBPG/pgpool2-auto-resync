#!/bin/bash
#this is for 3 node setup assuming 5432 as primary and 5433,5434 are standbys
# Improved resync.sh
# Args: $1 = old_host (node to resync), $2 = new_primary_host, $3 = old_port, $4 = new_port, $5 = old_data_dir
set -euo pipefail

OLD_HOST="${1:-}"
NEW_HOST="${2:-}"
OLD_PORT="${3:-}"
NEW_PORT="${4:-}"
OLD_PGDATA="${5:-}"

# Adjust these if your binaries or primary data path differ
PG_BIN="/usr/lib/postgresql/18/bin"
PRIMARY_PGDATA="/var/lib/postgresql/18/main"

PCP_PORT=9898
PCP_USER=postgres
LOG=/var/log/pgpool/resync.log

mkdir -p /var/log/pgpool
# Basic argument dump for debugging
echo "$(date '+%F %T') ==== resync.sh start ====" >> "$LOG"
echo "$(date '+%F %T') args: OLD_HOST=$OLD_HOST NEW_HOST=$NEW_HOST OLD_PORT=$OLD_PORT NEW_PORT=$NEW_PORT OLD_PGDATA=$OLD_PGDATA" >> "$LOG"
echo "$(date '+%F %T') environment: PG_BIN=$PG_BIN PCP_PORT=$PCP_PORT PCP_USER=$PCP_USER" >> "$LOG"

# Basic validation
if [ -z "$OLD_HOST" ] || [ -z "$NEW_HOST" ] || [ -z "$OLD_PORT" ] || [ -z "$NEW_PORT" ] || [ -z "$OLD_PGDATA" ]; then
  echo "$(date '+%F %T') ERROR: missing required arguments" >> "$LOG"
  exit 1
fi

# Stop target Postgres (ignore if already stopped)
echo "$(date '+%F %T') stopping target postgres (if running): $OLD_PGDATA" >> "$LOG"
sudo -u postgres "$PG_BIN/pg_ctl" -D "$OLD_PGDATA" stop -m immediate >> "$LOG" 2>&1 || true
sleep 2

# Try to auto-determine NODE_ID_FOR_PCP from pcp_node_info (safer than static mapping)
NODE_ID_FOR_PCP=""
PCP_OUT=$(sudo -u postgres pcp_node_info -h localhost -p "$PCP_PORT" -U "$PCP_USER" 2>/dev/null || true)
if [ -n "$PCP_OUT" ]; then
  # iterate lines and find matching host:port; pcp_node_info lines: "<host> <port> ..."
  idx=0
  while read -r line; do
    hs=$(echo "$line" | awk '{print $1}')
    pt=$(echo "$line" | awk '{print $2}')
    if [ "$hs" = "$OLD_HOST" ] && [ "$pt" = "$OLD_PORT" ]; then
      NODE_ID_FOR_PCP="$idx"
      break
    fi
    idx=$((idx+1))
  done <<< "$PCP_OUT"
fi

# Fallback static mapping if we couldn't determine node id
if [ -z "$NODE_ID_FOR_PCP" ]; then
  echo "$(date '+%F %T') WARN: could not detect node id via pcp_node_info; using port->id fallback" >> "$LOG"
  case "$OLD_PORT" in
    5432) NODE_ID_FOR_PCP=0 ;;
    5433) NODE_ID_FOR_PCP=1 ;;
    5434) NODE_ID_FOR_PCP=2 ;;
    *) echo "$(date '+%F %T') ERROR: unknown OLD_PORT=$OLD_PORT" >> "$LOG"; exit 1 ;;
  esac
fi
echo "$(date '+%F %T') NODE_ID_FOR_PCP=$NODE_ID_FOR_PCP" >> "$LOG"

# Ensure NEW_HOST/NEW_PORT present
if [ -z "$NEW_HOST" ] || [ -z "$NEW_PORT" ]; then
  echo "$(date '+%F %T') ERROR: NEW_HOST or NEW_PORT empty" >> "$LOG"
  exit 1
fi

# Print pg_controldata system ids (best-effort)
SYS_SRC=$(sudo -u postgres "$PG_BIN/pg_controldata" "$OLD_PGDATA" 2>/dev/null | awk -F: '/Database system identifier/ {print $2}' | tr -d ' ' || true)
SYS_TGT=$(sudo -u postgres "$PG_BIN/pg_controldata" "$PRIMARY_PGDATA" 2>/dev/null | awk -F: '/Database system identifier/ {print $2}' | tr -d ' ' || true)
echo "$(date '+%F %T') systemid old=$SYS_SRC current_primary=$SYS_TGT" >> "$LOG"

# Try pg_rewind
echo "$(date '+%F %T') Attempting pg_rewind: target=$OLD_PGDATA <- source=$NEW_HOST:$NEW_PORT" >> "$LOG"
if sudo -u postgres "$PG_BIN/pg_rewind" --target-pgdata="$OLD_PGDATA" --source-server="host=$NEW_HOST port=$NEW_PORT user=postgres dbname=postgres" >> "$LOG" 2>&1; then
  echo "$(date '+%F %T') pg_rewind succeeded" >> "$LOG"
else
  echo "$(date '+%F %T') pg_rewind failed; falling back to pg_basebackup" >> "$LOG"
  # Remove contents but keep directory itself
  LOG="/var/log/pgpool/resync.log"
  sudo rm -rf "$OLD_PGDATA" >> "$LOG" 2>&1
  sudo mkdir -p "$OLD_PGDATA" >> "$LOG" 2>&1
  sudo chown -R postgres:postgres "$OLD_PGDATA" >> "$LOG" 2>&1
  sudo chmod 700 "$OLD_PGDATA" >> "$LOG" 2>&1


  # Run pg_basebackup (requires repl user and .pgpass)
  echo "$(date '+%F %T') running pg_basebackup from $NEW_HOST:$NEW_PORT to $OLD_PGDATA" >> "$LOG"
  if ! sudo -u postgres "$PG_BIN/pg_basebackup" -h "$NEW_HOST" -p "$NEW_PORT" -U repl -D "$OLD_PGDATA" -Fp -Xs -P -R >> "$LOG" 2>&1; then
    echo "$(date '+%F %T') pg_basebackup failed; aborting resync" >> "$LOG"
    exit 1
  fi
  echo "$(date '+%F %T') pg_basebackup succeeded" >> "$LOG"
fi

# Ensure primary_conninfo exists in postgresql.auto.conf (safe append)
sudo -u postgres bash -c "
  conf=\"$OLD_PGDATA/postgresql.auto.conf\"
  if ! grep -q primary_conninfo \"\$conf\" 2>/dev/null; then
    echo \"primary_conninfo = 'host=$NEW_HOST port=$NEW_PORT user=repl passfile=/var/lib/postgresql/.pgpass'\" >> \"\$conf\"
  fi
"

# Create standby.signal for modern Postgres
sudo -u postgres touch "$OLD_PGDATA/standby.signal"

# Fix ownership/permissions
sudo chown -R postgres:postgres "$OLD_PGDATA"
sudo chmod 700 "$OLD_PGDATA" || true

case "$OLD_PORT" in
  5432) CONF="/etc/postgresql/18/main/postgresql.conf" ;;
  5433) CONF="/etc/postgresql/18/standby1/postgresql.conf" ;;
  5434) CONF="/etc/postgresql/18/standby2/postgresql.conf" ;;
  *) CONF="/etc/postgresql/18/main/postgresql.conf" ;;
esac


echo "$(date '+%F %T') starting postgres at $OLD_PGDATA using config $CONF"
sudo -u postgres "$PG_BIN/pg_ctl" -D "$OLD_PGDATA" -o "-c config_file=$CONF" -w start >>"$LOG" 2>&1 || echo "$(date '+%F %T') pg_ctl start returned non-zero (check postgres logs)"


# Wait for socket with pg_isready (up to ~30s)
attempt=0
until sudo -u postgres "$PG_BIN/pg_isready" -q -p "$OLD_PORT" || [ $attempt -ge 20 ]; do
  attempt=$((attempt+1))
  sleep 2
done
if [ $attempt -ge 15 ]; then
  echo "$(date '+%F %T') WARNING: server at $OLD_PGDATA didn't become ready within timeout" >> "$LOG"
fi

# Attach node to Pgpool via PCP with retries
RETRIES=6
i=0
while [ $i -lt $RETRIES ]; do
  if sudo -u postgres pcp_attach_node -h localhost -p "$PCP_PORT" -U "$PCP_USER" -n "$NODE_ID_FOR_PCP" >> "$LOG" 2>&1; then
    echo "$(date '+%F %T') pcp_attach_node succeeded for node $NODE_ID_FOR_PCP" >> "$LOG"
    break
  fi
  echo "$(date '+%F %T') pcp_attach_node attempt $((i+1)) failed; sleeping and retrying..." >> "$LOG"
  i=$((i+1))
  sleep 3
done
if [ $i -ge $RETRIES ]; then
  echo "$(date '+%F %T') ERROR: pcp_attach_node failed after $RETRIES attempts" >> "$LOG"
fi

echo "$(date '+%F %T') ==== resync complete ====" >> "$LOG"
exit 0
