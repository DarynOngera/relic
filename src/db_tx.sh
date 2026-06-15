# shellcheck shell=bash
# shellcheck source=src/db_utils.sh
# shellcheck source=src/db_lock.sh
# shellcheck source=src/db_storage.sh

db_tx_level=${db_tx_level:-0}

db=${db:-}

_db_tx_snapshot() {
  echo "${db}.tx.snapshot"
}

_db_tx_wal() {
  echo "${db}.tx.wal"
}

_db_tx_active() {
  [ "${db_tx_level:-0}" -gt 0 ]
}

_db_tx_ensure_inactive() {
  if _db_tx_active; then
    echo "Error: cannot run this operation inside a transaction" >&2
    return 1
  fi
  return 0
}

_db_tx_read_key_lines() {
  local key="$1"
  local snapshot
  snapshot=$(_db_tx_snapshot)
  awk -F, -v k="$key" '$1 == k' "$snapshot" "$(_db_tx_wal)" 2>/dev/null
}

_db_tx_read_all_lines() {
  local snapshot
  snapshot=$(_db_tx_snapshot)
  cat "$snapshot" "$(_db_tx_wal)" 2>/dev/null
}

_db_tx_append_wal() {
  local record="$1"
  echo "$record" >> "$(_db_tx_wal)"
}

_db_write_record() {
  local record="$1"
  if _db_tx_active; then
    _db_tx_append_wal "$record"
  else
    _db_append_wal "$record"
  fi
}

_db_read_key_lines_for_query() {
  local key="$1"
  if _db_tx_active; then
    _db_tx_read_key_lines "$key"
  else
    _db_read_key_lines "$key"
  fi
}

_db_read_all_lines_for_query() {
  if _db_tx_active; then
    _db_tx_read_all_lines
  else
    _db_read_all_lines
  fi
}

db_begin() {
  if [ -z "$db" ]; then
    db="db"
  fi

  if [ "$db_tx_level" -eq 0 ]; then
    if ! _db_check_flock; then
      return 1
    fi

    local snapshot wal
    snapshot=$(_db_tx_snapshot)
    wal=$(_db_tx_wal)

    if [ -f "$db" ]; then
      cp "$db" "$snapshot"
    else
      : > "$snapshot"
    fi
    : > "$wal"
  fi

  db_tx_level=$((db_tx_level + 1))
  return 0
}

db_commit() {
  if [ "$db_tx_level" -eq 0 ]; then
    echo "Error: no active transaction" >&2
    return 1
  fi

  db_tx_level=$((db_tx_level - 1))

  if [ "$db_tx_level" -gt 0 ]; then
    return 0
  fi

  if ! _db_check_flock; then
    return 1
  fi

  local wal snapshot
  wal=$(_db_tx_wal)
  snapshot=$(_db_tx_snapshot)

  (
    _db_lock_exclusive
    if [ -s "$wal" ]; then
      cat "$wal" >> "$db.wal"
    fi
    rm -f "$wal" "$snapshot"
  ) 200>"${db}.lock"

  return 0
}

db_rollback() {
  if [ "$db_tx_level" -eq 0 ]; then
    echo "Error: no active transaction" >&2
    return 1
  fi

  if [ "$db_tx_level" -gt 1 ]; then
    db_log_warn "Rolling back nested transaction; all levels will be aborted"
  fi

  local wal snapshot
  wal=$(_db_tx_wal)
  snapshot=$(_db_tx_snapshot)

  rm -f "$wal" "$snapshot"
  db_tx_level=0

  return 0
}
