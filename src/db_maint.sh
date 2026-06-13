# shellcheck shell=bash
# shellcheck source=src/db_utils.sh
# shellcheck source=src/db_lock.sh
# shellcheck source=src/db_storage.sh

db=${db:-}

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
}

db_migrate() {
  _db_check_flock || return 1

  if [ ! -f "$db" ]; then
    echo "Error: database does not exist" >&2
    return 1
  fi

  local tmp
  tmp=$(mktemp -p "$(dirname "$db")")
  if [ -z "$tmp" ]; then
    echo "Error: mktemp failed" >&2
    return 1
  fi

  trap 'rm -f "$tmp"; exit 1' INT TERM

  local line_num=0 migrated=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [ -z "$line" ] && continue

    local field_count
    field_count=$(echo "$line" | awk -F',' '{print NF}')
    if [ "$field_count" -eq 4 ]; then
      echo "$line" >> "$tmp"
      migrated=$((migrated + 1))
    elif [ "$field_count" -eq 3 ]; then
      local checksum
      checksum=$(_db_checksum "$line")
      echo "$line,$checksum" >> "$tmp"
      migrated=$((migrated + 1))
    else
      echo "Error: line $line_num: invalid format (expected 3 or 4 fields, got $field_count)" >&2
      rm -f "$tmp"
      trap - INT TERM
      return 1
    fi
  done < "$db"

  (
    _db_lock_exclusive
    mv "$tmp" "$db"
    : > "$db.wal"
  ) 200>"${db}.lock"

  trap - INT TERM
  echo "Migration complete: $migrated records migrated" >&2
  return 0
}

db_sync() {
  _db_check_flock || return 1

  (
    _db_lock_exclusive
    _db_sync_wal
  ) 200>"${db}.lock"

  return 0
}

db_verify() {
  _db_check_flock || return 1

  (
    _db_lock_shared
    local errors=0
    local total_lines=0

    _verify_file() {
      local file="$1"
      local line_num=0
      while IFS= read -r line; do
        line_num=$((line_num + 1))
        total_lines=$((total_lines + 1))
        [ -z "$line" ] && continue

        local field_count
        field_count=$(echo "$line" | awk -F',' '{print NF}')
        if [ "$field_count" -ne 4 ]; then
          echo "Error: $file line $line_num: invalid format (expected 4 fields, got $field_count)" >&2
          errors=$((errors + 1))
          continue
        fi

        local payload="${line%,*}"
        local checksum="${line##*,}"
        local computed
        computed=$(_db_checksum "$payload")
        if [ "$checksum" != "$computed" ]; then
          echo "Error: $file line $line_num: checksum mismatch" >&2
          errors=$((errors + 1))
        fi
      done < "$file"
    }

    if [ -f "$db" ]; then
      _verify_file "$db"
    fi

    if [ -f "$db.wal" ] && [ -s "$db.wal" ]; then
      _verify_file "$db.wal"
    fi

    if [ "$errors" -gt 0 ]; then
      echo "Found $errors corrupted record(s) out of $total_lines" >&2
      return 1
    fi

    echo "Database verified: $total_lines records, clean"
    return 0
  ) 200>"${db}.lock"
}

db_stats() {
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
  _db_check_flock || return 1

  (
    _db_lock_exclusive
    local record
    record=$(_db_format_record "__system__" "__cleared__")
    echo "$record" >> "$db"
    : > "$db.wal"
  ) 200>"${db}.lock"

  return 0
}

db_count() {
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
      if [ "$value" != "__deleted__" ]; then
        count=$((count + 1))
      fi
    done

    echo "$count"
    return 0
  ) 200>"${db}.lock"
}

db_size() {
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
