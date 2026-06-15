# shellcheck shell=bash

_db_checksum() {
  local payload="$1"
  echo -n "$payload" | sha256sum | cut -d' ' -f1
}

_db_timestamp() {
  date -Iseconds
}

_db_validate_key() {
  local key="$1"
  if [ -z "$key" ]; then
    echo "Error: key cannot be empty" >&2
    return 1
  fi
  if [[ "$key" == *\"* ]]; then
    echo "Error: key cannot contain quotes" >&2
    return 1
  fi
  if [[ "$key" == *,* ]]; then
    echo "Error: key cannot contain commas" >&2
    return 1
  fi
  return 0
}

_db_validate_key_value() {
  local key="$1" value="$2"
  if [ -z "$key" ] || [ -z "$value" ]; then
    echo "Error: key and value cannot be empty" >&2
    return 1
  fi
  if [[ "$key" == *\"* ]] || [[ "$value" == *\"* ]]; then
    echo "Error: key and value cannot contain quotes" >&2
    return 1
  fi
  if [[ "$key" == *,* ]]; then
    echo "Error: key cannot contain commas" >&2
    return 1
  fi
  return 0
}

_db_format_record() {
  local key="$1" value="$2"
  local timestamp payload checksum
  timestamp=$(_db_timestamp)
  payload="$key,\"$value\",$timestamp"
  checksum=$(_db_checksum "$payload")
  echo "$payload,$checksum"
}

_db_extract_value() {
  local payload="$1"
  local prefix="${payload#*,\"}"
  echo "${prefix%\",*}"
}

_db_extract_timestamp() {
  local payload="$1"
  echo "${payload##*\",}"
}

_db_is_system_key() {
  local key="$1"
  [[ "$key" == __* ]]
}

_db_is_integer() {
  local value="$1"
  [[ "$value" =~ ^-?[0-9]+$ ]]
}

_db_human_readable_size() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
  else
    echo "${bytes}B"
  fi
}

_db_log_level_value() {
  local level="$1"
  case "$level" in
    debug) echo 0 ;;
    info)  echo 1 ;;
    warn)  echo 2 ;;
    error) echo 3 ;;
    *)     echo 2 ;;
  esac
}

_db_log() {
  local level="$1" message="$2"
  local configured_level
  configured_level=${DB_LOG_LEVEL:-warn}

  local level_value configured_value
  level_value=$(_db_log_level_value "$level")
  configured_value=$(_db_log_level_value "$configured_level")

  if [ "$level_value" -lt "$configured_value" ]; then
    return 0
  fi

  local timestamp
  timestamp=$(_db_timestamp)
  local formatted="[$timestamp] [$level] $message"

  echo "$formatted" >&2

  if [ -n "${DB_LOG_FILE:-}" ]; then
    echo "$formatted" >> "$DB_LOG_FILE"
  fi
}

db_log_debug() { _db_log "debug" "$1"; }
db_log_info()  { _db_log "info"  "$1"; }
db_log_warn()  { _db_log "warn"  "$1"; }
db_log_error() { _db_log "error" "$1"; }

_db_memory_usage_kb() {
  if [ -f /proc/self/status ]; then
    awk '/VmRSS/{print $2}' /proc/self/status
  elif command -v ps >/dev/null 2>&1; then
    ps -o rss= -p "$$" 2>/dev/null
  else
    echo "0"
  fi
}
