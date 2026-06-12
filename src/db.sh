#!/bin/bash

db_init() {
  if [ -z "$db" ]; then
    db="db"
  fi
  if [ ! -f "$db" ]; then
    touch "$db"
  fi
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

  local tp
  tp=$(date -Iseconds)
  echo "$1,\"$2\",$tp" >> "$tmp"
  (
    flock -x 200
    cat "$tmp" >> "$db"
    rm -f "$tmp"
    sync
  ) 200>"${db}.lock"

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
    if [ ! -f "$db" ]; then
      return 1
    fi
    local line
    line=$(grep "^$1,\"" "$db" 2>/dev/null | tail -n 1)
    if [ -z "$line" ]; then
      return 1
    fi
    local value
    value=$(echo "$line" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
    if [ "$value" = "__deleted__" ]; then
      return 1
    fi
    echo "$value"
  ) 200>"${db}.lock"
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

  local tp
  tp=$(date -Iseconds)
  echo "$1,\"__deleted__\",$tp" >> "$tmp"
  (
    flock -x 200
    cat "$tmp" >> "$db"
    rm -f "$tmp"
    sync
  ) 200>"${db}.lock"

  return 0
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
    if [ ! -f "$db" ]; then
      return 1
    fi
    grep "^$1,\"" "$db" 2>/dev/null | while IFS= read -r line; do
      local value timestamp
      value=$(echo "$line" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
      timestamp=$(echo "$line" | sed 's/^.*,"//' | sed 's/"$//')
      if [ "$value" = "__deleted__" ]; then
        echo "[DELETED] @ $timestamp"
      else
        echo "$value @ $timestamp"
      fi
    done
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
    if [ ! -f "$db" ]; then
      return 1
    fi
    local line
    line=$(grep "^$1,\"" "$db" 2>/dev/null | tail -n 1)
    if [ -z "$line" ]; then
      return 1
    fi
    local value
    value=$(echo "$line" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
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
    if [ ! -f "$db" ]; then
      return 1
    fi
    cut -d, -f1 "$db" | sort -u | while read -r key; do
      if db_exists "$key"; then
        echo "$key"
      fi
    done
  ) 200>"${db}.lock"
}

db_stats() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi
  (
    flock -s 200
    if [ ! -f "$db" ] || [ ! -s "$db" ]; then
      echo "Database is empty or does not exist"
      return 1
    fi
    local total_records unique_keys file_size
    total_records=$(wc -l < "$db")
    unique_keys=$(cut -d, -f1 "$db" | sort -u | wc -l)
    file_size=$(stat -c %s "$db" 2>/dev/null || stat -f %z "$db")
    echo "Total records: $total_records"
    echo "Unique keys: $unique_keys"
    echo "File size: $file_size bytes"
  ) 200>"${db}.lock"
}
