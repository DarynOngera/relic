# shellcheck shell=bash

db=${db:-}

_db_replica_enabled() {
  [ -n "${DB_REPLICA:-}" ] || [ -n "${DB_REPLICA_CMD:-}" ]
}

_db_replica_append() {
  local record="$1"

  if [ -n "${DB_REPLICA:-}" ]; then
    if ! mkdir -p "$(dirname "$DB_REPLICA")" 2>/dev/null; then
      db_log_warn "Failed to create replica directory"
    else
      if echo "$record" >> "$DB_REPLICA.wal"; then
        if command -v sync >/dev/null 2>&1; then
          sync "$DB_REPLICA.wal" 2>/dev/null || true
        fi
      else
        db_log_warn "Failed to append to replica WAL $DB_REPLICA.wal"
      fi
    fi
  fi

  if [ -n "${DB_REPLICA_CMD:-}" ]; then
    if ! printf '%s\n' "$record" | eval "$DB_REPLICA_CMD" >/dev/null 2>&1; then
      db_log_warn "Replica command failed: $DB_REPLICA_CMD"
    fi
  fi
}

db_replica_sync() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  if [ -z "${DB_REPLICA:-}" ]; then
    echo "Error: DB_REPLICA is not set" >&2
    return 1
  fi

  if [ ! -f "$DB_REPLICA.wal" ]; then
    return 0
  fi

  (
    _db_lock_exclusive
    if [ -s "$DB_REPLICA.wal" ]; then
      cat "$DB_REPLICA.wal" >> "$DB_REPLICA"
      : > "$DB_REPLICA.wal"
      if command -v sync >/dev/null 2>&1; then
        sync "$DB_REPLICA" 2>/dev/null || true
      fi
    fi
  ) 200>"${db}.lock"

  return 0
}
