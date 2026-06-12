#!/bin/bash

# Production-grade append-only key-value database in pure Bash
# Record format: key,"value",timestamp,sha256sum
# WAL file: db.wal (same format, flushed to db via db_sync)

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

  # Auto-migrate old format (3 fields) to new format (4 fields)
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
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock is required for migration" >&2
    return 1
  fi

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

  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [ -z "$line" ] && continue

    local field_count
    field_count=$(echo "$line" | awk -F',' '{print NF}')
    if [ "$field_count" -eq 4 ]; then
      echo "$line" >> "$tmp"
    elif [ "$field_count" -eq 3 ]; then
      local checksum
      checksum=$(echo -n "$line" | sha256sum | cut -d' ' -f1)
      echo "$line,$checksum" >> "$tmp"
    else
      echo "Error: line $line_num: invalid format (expected 3 or 4 fields, got $field_count)" >&2
      rm -f "$tmp"
      trap - INT TERM
      return 1
    fi
  done < "$db"

  (
    flock -x 200
    mv "$tmp" "$db"
    > "$db.wal"
  ) 200>"${db}.lock"

  trap - INT TERM
  echo "Migration complete: $line_num records migrated" >&2
  return 0
}

db_sync() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi

  if [ ! -s "$db.wal" ]; then
    return 0
  fi

  (
    flock -x 200
    cat "$db.wal" >> "$db"
    > "$db.wal"
    sync
  ) 200>"${db}.lock"

  return 0
}

db_verify() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi

  local errors=0
  local total_lines=0

  (
    flock -s 200

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
        computed=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
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

db_set() {
  if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Error: key and value cannot be empty" >&2
    return 1
  fi
  if [[ "$1" == *\"* ]] || [[ "$2" == *\"* ]]; then
    echo "Error: key and value cannot contain quotes" >&2
    return 1
  fi
  if [[ "$1" == *,* ]]; then
    echo "Error: key cannot contain commas" >&2
    return 1
  fi
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  if [ -z "$tmp" ]; then
    echo "Error: mktemp failed" >&2
    return 1
  fi

  trap 'rm -f "$tmp"; exit 1' INT TERM

  local tp
  tp=$(date -Iseconds)
  local payload="$1,\"$2\",$tp"
  local checksum
  checksum=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
  echo "$payload,$checksum" >> "$tmp"

  (
    flock -x 200
    cat "$tmp" >> "$db.wal"
    rm -f "$tmp"
  ) 200>"${db}.lock"

  trap - INT TERM
  return 0
}

db_delete() {
  if [ -z "$1" ]; then
    echo "Error: key cannot be empty" >&2
    return 1
  fi
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  if [ -z "$tmp" ]; then
    echo "Error: mktemp failed" >&2
    return 1
  fi

  trap 'rm -f "$tmp"; exit 1' INT TERM

  local tp
  tp=$(date -Iseconds)
  local payload="$1,\"__deleted__\",$tp"
  local checksum
  checksum=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
  echo "$payload,$checksum" >> "$tmp"

  (
    flock -x 200
    cat "$tmp" >> "$db.wal"
    rm -f "$tmp"
  ) 200>"${db}.lock"

  trap - INT TERM
  return 0
}

db_get() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi
  if [ -z "$1" ]; then
    echo "Error: key cannot be empty" >&2
    return 1
  fi

  (
    flock -s 200
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local line
    line=$(cat "$db" "$db.wal" 2>/dev/null | grep "^$1,\"" | tail -n 1)

    if [ -z "$line" ]; then
      return 1
    fi

    local payload="${line%,*}"
    local checksum="${line##*,}"
    local computed
    computed=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
    if [ "$checksum" != "$computed" ]; then
      echo "Error: checksum mismatch" >&2
      return 1
    fi

    local value
    value=$(echo "$payload" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
    if [ "$value" = "__deleted__" ]; then
      return 1
    fi
    echo "$value"
  ) 200>"${db}.lock"
}

db_history() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi
  if [ -z "$1" ]; then
    echo "Error: key cannot be empty" >&2
    return 1
  fi

  (
    flock -s 200
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local has_error=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue

      local payload="${line%,*}"
      local checksum="${line##*,}"
      local computed
      computed=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch" >&2
        has_error=1
        break
      fi

      local value timestamp
      value=$(echo "$payload" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
      timestamp="${payload##*,}"
      if [ "$value" = "__deleted__" ]; then
        echo "[DELETED] @ $timestamp"
      else
        echo "$value @ $timestamp"
      fi
    done < <(cat "$db" "$db.wal" 2>/dev/null | grep "^$1,\"")

    return "$has_error"
  ) 200>"${db}.lock"
}

db_exists() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi
  if [ -z "$1" ]; then
    echo "Error: key cannot be empty" >&2
    return 1
  fi

  (
    flock -s 200
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local line
    line=$(cat "$db" "$db.wal" 2>/dev/null | grep "^$1,\"" | tail -n 1)

    if [ -z "$line" ]; then
      return 1
    fi

    local payload="${line%,*}"
    local checksum="${line##*,}"
    local computed
    computed=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
    if [ "$checksum" != "$computed" ]; then
      echo "Error: checksum mismatch" >&2
      return 1
    fi

    local value
    value=$(echo "$payload" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
    if [ "$value" = "__deleted__" ]; then
      return 1
    fi
    return 0
  ) 200>"${db}.lock"
}

db_list() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi

  (
    flock -s 200
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local has_error=0
    local keys=""

    while IFS= read -r line; do
      [ -z "$line" ] && continue

      local payload="${line%,*}"
      local checksum="${line##*,}"
      local computed
      computed=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch" >&2
        has_error=1
        break
      fi

      local key="${line%%,*}"
      [ -z "$key" ] && continue

      if [[ "$keys" != *"$key"* ]]; then
        keys="$keys$key"$'\n'
      fi
    done < <(cat "$db" "$db.wal" 2>/dev/null)

    if [ "$has_error" -eq 1 ]; then
      return 1
    fi

    echo "$keys" | sort -u | while IFS= read -r key; do
      [ -z "$key" ] && continue
      local line
      line=$(cat "$db" "$db.wal" 2>/dev/null | grep "^$key,\"" | tail -n 1)
      local payload="${line%,*}"
      local value
      value=$(echo "$payload" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
      if [ "$value" != "__deleted__" ]; then
        echo "$key"
      fi
    done

    return 0
  ) 200>"${db}.lock"
}

db_stats() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi

  (
    flock -s 200
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
      computed=$(echo -n "$payload" | sha256sum | cut -d' ' -f1)
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch" >&2
        has_error=1
        break
      fi
    done < <(cat "$db" "$db.wal" 2>/dev/null)

    if [ "$has_error" -eq 1 ]; then
      return 1
    fi

    if [ "$total_records" -eq 0 ]; then
      echo "Database is empty or does not exist"
      return 1
    fi

    local unique_keys
    unique_keys=$(cat "$db" "$db.wal" 2>/dev/null | cut -d, -f1 | sort -u | wc -l)
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
