# shellcheck shell=bash
# shellcheck source=src/db_lock.sh

db=${db:-}

_db_fsync_wal() {
  if [ "${DB_NO_FSYNC:-0}" = "1" ]; then
    return 0
  fi
  if command -v sync >/dev/null 2>&1; then
    sync "$db.wal" 2>/dev/null || true
  fi
}

_db_append_wal() {
  local record="$1"
  echo "$record" >> "$db.wal"
  _db_fsync_wal
  if _db_replica_enabled; then
    _db_replica_append "$record"
  fi
}

_db_sync_wal() {
  if [ ! -s "$db.wal" ]; then
    return 0
  fi
  cat "$db.wal" >> "$db"
  : > "$db.wal"
  sync
}

_db_segment_files() {
  local seg
  for seg in "${db}.3" "${db}.2" "${db}.1"; do
    if [ -f "$seg" ]; then
      echo "$seg"
    elif [ -f "$seg.gz" ]; then
      echo "$seg.gz"
    fi
  done
}

_db_cat_file() {
  local file="$1"
  if [[ "$file" == *.gz ]]; then
    if command -v gzip >/dev/null 2>&1; then
      gzip -dc "$file" 2>/dev/null
    fi
  else
    cat "$file" 2>/dev/null
  fi
}

_db_read_key_lines() {
  local key="$1"
  if [ -z "$db" ]; then
    return 1
  fi
  if [ ! -f "$db" ] && [ ! -f "$db.wal" ] && [ -z "$(_db_segment_files)" ]; then
    return 1
  fi

  local seg
  for seg in $(_db_segment_files); do
    _db_cat_file "$seg" | awk -F, -v k="$key" '$1 == k'
  done
  awk -F, -v k="$key" '$1 == k' "$db" "$db.wal" 2>/dev/null
}

_db_read_all_lines() {
  if [ -z "$db" ]; then
    return 1
  fi
  if [ ! -f "$db" ] && [ ! -f "$db.wal" ] && [ -z "$(_db_segment_files)" ]; then
    return 1
  fi

  local seg
  for seg in $(_db_segment_files); do
    _db_cat_file "$seg"
  done
  _db_cat_file "$db"
  _db_cat_file "$db.wal"
}
