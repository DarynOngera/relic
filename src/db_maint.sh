# shellcheck shell=bash
# shellcheck source=src/db_utils.sh
# shellcheck source=src/db_lock.sh
# shellcheck source=src/db_storage.sh

db=${db:-}
_DB_SCHEMA_VERSION=1

_db_get_schema_version() {
  local line payload checksum computed value
  line=$(_db_read_key_lines "__schema_version__" | tail -n 1)
  [ -z "$line" ] && echo 0 && return 0

  payload="${line%,*}"
  checksum="${line##*,}"
  computed=$(_db_checksum "$payload")
  if [ "$checksum" != "$computed" ]; then
    echo 0
    return 0
  fi

  value=$(_db_extract_value "$payload")
  if _db_is_integer "$value"; then
    echo "$value"
  else
    echo 0
  fi
}

db_init() {
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "Error: sha256sum is required" >&2
    return 1
  fi

  if [ -z "$db" ]; then
    db="db"
  fi

  if [ ! -f "$db" ]; then
    touch "$db"
  fi

  if [ ! -f "$db.wal" ]; then
    touch "$db.wal"
  fi

  if [ -f "${db}.tx.wal" ] || [ -f "${db}.tx.snapshot" ]; then
    db_log_warn "Found leftover transaction files; rolling back incomplete transaction"
    rm -f "${db}.tx.wal" "${db}.tx.snapshot"
  fi

  if [ -f "$db" ] && [ -s "$db" ]; then
    local first_line
    first_line=$(grep -v '^$' "$db" | head -n 1)
    if [ -n "$first_line" ]; then
      local field_count
      field_count=$(echo "$first_line" | awk -F',' '{print NF}')
      if [ "$field_count" -eq 3 ]; then
        echo "Migrating database to new format..." >&2
        db_migrate
      fi
    fi
  fi

  if [ -f "$db" ] && [ ! -s "$db" ]; then
    (
      _db_lock_exclusive
      local record
      record=$(_db_format_record "__schema_version__" "$_DB_SCHEMA_VERSION")
      echo "$record" >> "$db"
    ) 200>"${db}.lock"
  fi

}

db_migrate() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  if [ ! -f "$db" ]; then
    echo "Error: database does not exist" >&2
    return 1
  fi

  _db_sync_wal

  local current_version
  current_version=$(_db_get_schema_version)

  if [ ! -d "$(dirname "$db")/migrations" ] && [ ! -d "migrations" ]; then
    if [ "$current_version" -lt 1 ]; then
      echo "Error: migrations directory not found; cannot migrate from version $current_version" >&2
      return 1
    fi
    echo "No migrations directory found; database is at version $current_version" >&2
    return 0
  fi

  local migrations_dir
  if [ -d "migrations" ]; then
    migrations_dir="migrations"
  else
    migrations_dir="$(dirname "$db")/migrations"
  fi

  local applied=0
  local script
  for script in "$migrations_dir"/v*_to_v*.sh; do
    [ -f "$script" ] || continue

    local base from to_raw to
    base="${script##*/}"
    base="${base%.sh}"
    base="${base#v}"
    from="${base%%_to_*}"
    to_raw="${base#*_to_}"
    to="${to_raw#v}"

    if ! _db_is_integer "$from" || ! _db_is_integer "$to"; then
      db_log_warn "Skipping migration script with invalid name: $script"
      continue
    fi

    if [ "$current_version" -ne "$from" ]; then
      continue
    fi

    if [ "$to" -le "$current_version" ]; then
      db_log_warn "Skipping migration script that does not advance version: $script"
      continue
    fi

    if ! (
      _db_lock_exclusive
      if ! source "$script"; then
        echo "Error: failed to load migration script $script" >&2
        return 1
      fi
      if ! declare -f migrate >/dev/null 2>&1; then
        echo "Error: migration script $script does not define migrate()" >&2
        return 1
      fi
      if ! migrate "$db"; then
        echo "Error: migration $script failed" >&2
        return 1
      fi
      local version_record migration_record
      version_record=$(_db_format_record "__schema_version__" "$to")
      migration_record=$(_db_format_record "__migration_applied__" "$from:$to")
      echo "$version_record" >> "$db"
      echo "$migration_record" >> "$db"
    ) 200>"${db}.lock"; then
      return 1
    fi

    current_version=$to
    applied=$((applied + 1))
  done

  if [ "$applied" -eq 0 ]; then
    echo "No migrations applied; database is at version $current_version" >&2
  else
    echo "Migration complete: $applied migration(s) applied; database is now version $current_version" >&2
  fi

  return 0
}

db_sync() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  (
    _db_lock_exclusive
    _db_sync_wal
  ) 200>"${db}.lock"

  return 0
}

db_verify() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  (
    _db_lock_shared
    local errors=0
    local total_lines=0

    local line_num=0
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      total_lines=$((total_lines + 1))
      [ -z "$line" ] && continue

      local field_count
      field_count=$(echo "$line" | awk -F',' '{print NF}')
      if [ "$field_count" -ne 4 ]; then
        echo "Error: $db line $line_num: invalid format (expected 4 fields, got $field_count)" >&2
        errors=$((errors + 1))
        continue
      fi

      local payload="${line%,*}"
      local checksum="${line##*,}"
      local computed
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: $db line $line_num: checksum mismatch" >&2
        errors=$((errors + 1))
      fi
    done < <(cat "$db" 2>/dev/null)

    line_num=0
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      total_lines=$((total_lines + 1))
      [ -z "$line" ] && continue

      local field_count
      field_count=$(echo "$line" | awk -F',' '{print NF}')
      if [ "$field_count" -ne 4 ]; then
        echo "Error: $db.wal line $line_num: invalid format (expected 4 fields, got $field_count)" >&2
        errors=$((errors + 1))
        continue
      fi

      local payload="${line%,*}"
      local checksum="${line##*,}"
      local computed
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: $db.wal line $line_num: checksum mismatch" >&2
        errors=$((errors + 1))
      fi
    done < <(cat "$db.wal" 2>/dev/null)

    if [ "$errors" -gt 0 ]; then
      echo "Found $errors corrupted record(s) out of $total_lines" >&2
      return 1
    fi

    echo "Database verified: $total_lines records, clean"
    return 0
  ) 200>"${db}.lock"
}

db_stats() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      echo "Database is empty or does not exist"
      return 1
    fi

    local has_error=0
    local total_records=0

    while IFS= read -r line; do
      [ -z "$line" ] && continue
      total_records=$((total_records + 1))

      local payload="${line%,*}"
      local checksum="${line##*,}"
      local computed
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch" >&2
        has_error=1
        break
      fi
    done < <(_db_read_all_lines)

    if [ "$has_error" -eq 1 ]; then
      return 1
    fi

    if [ "$total_records" -eq 0 ]; then
      echo "Database is empty or does not exist"
      return 1
    fi

    local unique_keys
    unique_keys=$(_db_read_all_lines | cut -d, -f1 | sort -u | wc -l)
    local file_size
    file_size=$(stat -c %s "$db" 2>/dev/null || stat -f %z "$db")
    local wal_size
    wal_size=$(stat -c %s "$db.wal" 2>/dev/null || stat -f %z "$db.wal")

    echo "Total records: $total_records"
    echo "Unique keys: $unique_keys"
    echo "File size: $file_size bytes"
    echo "WAL size: $wal_size bytes"
  ) 200>"${db}.lock"
}

db_clear() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  (
    _db_lock_exclusive
    : > "$db"
    : > "$db.wal"
    local record
    record=$(_db_format_record "__system__" "__cleared__")
    echo "$record" >> "$db"
  ) 200>"${db}.lock"

  return 0
}

db_count() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      echo "0"
      return 0
    fi

    local has_error=0
    declare -A seen

    while IFS= read -r line; do
      [ -z "$line" ] && continue

      local payload checksum computed key
      payload="${line%,*}"
      checksum="${line##*,}"
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch" >&2
        has_error=1
        break
      fi

      key="${line%%,*}"
      [ -z "$key" ] && continue
      _db_is_system_key "$key" && continue
      seen[$key]=1

    done < <(_db_read_all_lines)

    if [ "$has_error" -eq 1 ]; then
      return 1
    fi

    local count=0
    for key in "${!seen[@]}"; do
      [ -z "$key" ] && continue
      _db_is_system_key "$key" && continue
      local line payload value
      line=$(_db_read_key_lines "$key" | tail -n 1)
      payload="${line%,*}"
      value=$(_db_extract_value "$payload")
      if [ "$value" != "__deleted__" ] && ! _db_is_expired "$key"; then
        count=$((count + 1))
      fi
    done

    echo "$count"
    return 0
  ) 200>"${db}.lock"
}

db_size() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  (
    _db_lock_shared
    local file_size=0 wal_size=0 total
    if [ -f "$db" ]; then
      file_size=$(stat -c %s "$db" 2>/dev/null || stat -f %z "$db")
    fi
    if [ -f "$db.wal" ]; then
      wal_size=$(stat -c %s "$db.wal" 2>/dev/null || stat -f %z "$db.wal")
    fi
    total=$((file_size + wal_size))
    _db_human_readable_size "$total"
    return 0
  ) 200>"${db}.lock"
}

db_compact() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
    return 0
  fi

  local tmp
  tmp=$(mktemp -p "$(dirname "$db")")
  if [ -z "$tmp" ]; then
    echo "Error: mktemp failed" >&2
    return 1
  fi

  trap 'rm -f "$tmp"; exit 1' INT TERM

  (
    _db_lock_exclusive

    local has_error=0
    declare -A latest

    while IFS= read -r line; do
      [ -z "$line" ] && continue

      local payload checksum computed key
      payload="${line%,*}"
      checksum="${line##*,}"
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch during compaction" >&2
        has_error=1
        break
      fi

      key="${line%%,*}"
      [ -z "$key" ] && continue
      latest[$key]="$line"

    done < <(_db_read_all_lines)

    if [ "$has_error" -eq 1 ]; then
      rm -f "$tmp"
      return 1
    fi

    declare -A expired
    for key in "${!latest[@]}"; do
      if _db_is_expired "$key"; then
        expired[$key]=1
      fi
    done

    for key in "${!latest[@]}"; do
      [ -z "$key" ] && continue
      if [ "${expired[$key]:-}" = "1" ]; then
        continue
      fi
      if [[ "$key" == __ttl__:* ]]; then
        local target_key="${key#__ttl__:}"
        if [ "${expired[$target_key]:-}" = "1" ]; then
          continue
        fi
      fi
      local record="${latest[$key]}"
      local record_payload="${record%,*}"
      local record_value
      record_value=$(_db_extract_value "$record_payload")
      if [ "$record_value" != "__deleted__" ]; then
        echo "$record" >> "$tmp"
      fi
    done

    mv "$tmp" "$db"
    : > "$db.wal"
  ) 200>"${db}.lock"

  trap - INT TERM
  return 0
}

db_vacuum() {
  _db_tx_ensure_inactive || return 1
  db_compact || return 1
  db_verify || return 1
  return 0
}

db_backup() {
  if [ $# -ne 1 ]; then
    echo "Error: db_backup requires a destination path" >&2
    return 1
  fi
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  local dest="$1"

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      echo "Error: database does not exist" >&2
      return 1
    fi

    local errors=0
    local compress="${DB_BACKUP_COMPRESS:-0}"
    if [ "$compress" = "1" ] && command -v gzip >/dev/null 2>&1; then
      if [ -f "$db" ] && ! (cp "$db" "$dest" && gzip -f "$dest"); then
        echo "Error: failed to backup database" >&2
        errors=$((errors + 1))
      fi
      if [ -f "$db.wal" ] && ! (cp "$db.wal" "$dest.wal" && gzip -f "$dest.wal"); then
        echo "Error: failed to backup WAL" >&2
        errors=$((errors + 1))
      fi
    else
      if [ -f "$db" ] && ! cp "$db" "$dest"; then
        echo "Error: failed to backup database" >&2
        errors=$((errors + 1))
      fi
      if [ -f "$db.wal" ] && ! cp "$db.wal" "$dest.wal"; then
        echo "Error: failed to backup WAL" >&2
        errors=$((errors + 1))
      fi
    fi

    if [ "$errors" -gt 0 ]; then
      return 1
    fi
    return 0
  ) 200>"${db}.lock"
}

db_restore() {
  if [ $# -ne 1 ]; then
    echo "Error: db_restore requires a source path" >&2
    return 1
  fi
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  local src="$1"

  local src_file="$src"
  if [ -f "$src.gz" ]; then
    src_file="$src.gz"
  elif [ ! -f "$src" ]; then
    echo "Error: backup source does not exist" >&2
    return 1
  fi

  if [ -s "$db" ] || [ -s "$db.wal" ]; then
    echo "Error: cannot restore over a non-empty database" >&2
    return 1
  fi

  (
    _db_lock_exclusive

    local line_num=0 errors=0
    local input_cmd="cat"
    if [[ "$src_file" == *.gz ]]; then
      input_cmd="gzip -dc"
    fi
    while IFS= read -r line; do
      line_num=$((line_num + 1))
      [ -z "$line" ] && continue

      local field_count
      field_count=$(echo "$line" | awk -F',' '{print NF}')
      if [ "$field_count" -ne 4 ]; then
        echo "Error: $src line $line_num: invalid format" >&2
        errors=$((errors + 1))
        continue
      fi

      local payload="${line%,*}"
      local checksum="${line##*,}"
      local computed
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: $src line $line_num: checksum mismatch" >&2
        errors=$((errors + 1))
      fi
    done < <($input_cmd "$src_file")

    if [ "$errors" -gt 0 ]; then
      return 1
    fi

    if ! cp "$src_file" "$db.gz.tmp" 2>/dev/null; then
      echo "Error: failed to restore database" >&2
      return 1
    fi
    if [[ "$src_file" == *.gz ]]; then
      if ! gzip -dc "$db.gz.tmp" > "$db"; then
        rm -f "$db.gz.tmp"
        echo "Error: failed to decompress database" >&2
        return 1
      fi
      rm -f "$db.gz.tmp"
    else
      mv "$db.gz.tmp" "$db"
    fi

    local wal_src="$src.wal"
    if [ -f "$src.wal.gz" ]; then
      wal_src="$src.wal.gz"
    fi
    if [ -f "$wal_src" ]; then
      if [[ "$wal_src" == *.gz ]]; then
        if ! gzip -dc "$wal_src" > "$db.wal"; then
          echo "Error: failed to decompress WAL" >&2
          return 1
        fi
      else
        if ! cp "$wal_src" "$db.wal"; then
          echo "Error: failed to restore WAL" >&2
          return 1
        fi
      fi
    else
      : > "$db.wal"
    fi

    return 0
  ) 200>"${db}.lock"
}

db_truncate() {
  _db_tx_ensure_inactive || return 1
  _db_check_flock || return 1

  local max_bytes="${1:-10485760}"
  if ! _db_is_integer "$max_bytes" || [ "$max_bytes" -le 0 ]; then
    echo "Error: max size must be a positive integer" >&2
    return 1
  fi

  (
    _db_lock_exclusive
    if [ ! -f "$db" ]; then
      return 0
    fi

    local file_size
    file_size=$(stat -c %s "$db" 2>/dev/null || stat -f %z "$db")
    if [ "$file_size" -le "$max_bytes" ]; then
      return 0
    fi

    rm -f "${db}.3" "${db}.3.gz"
    if [ -f "${db}.2" ]; then
      mv "${db}.2" "${db}.3"
    elif [ -f "${db}.2.gz" ]; then
      mv "${db}.2.gz" "${db}.3.gz"
    fi
    if [ -f "${db}.1" ]; then
      mv "${db}.1" "${db}.2"
    elif [ -f "${db}.1.gz" ]; then
      mv "${db}.1.gz" "${db}.2.gz"
    fi
    mv "$db" "${db}.1"
    if command -v gzip >/dev/null 2>&1; then
      gzip -f "${db}.1"
    fi
    : > "$db"

    return 0
  ) 200>"${db}.lock"
}
