# shellcheck shell=bash
# shellcheck source=src/db_lock.sh

db=${db:-}

_db_append_wal() {
  local record="$1"
  echo "$record" >> "$db.wal"
}

_db_sync_wal() {
  if [ ! -s "$db.wal" ]; then
    return 0
  fi
  cat "$db.wal" >> "$db"
  : > "$db.wal"
  sync
}

_db_read_key_lines() {
  local key="$1"
  awk -F, -v k="$key" '$1 == k' "$db" "$db.wal" 2>/dev/null
}

_db_read_all_lines() {
  cat "$db" "$db.wal" 2>/dev/null
}
