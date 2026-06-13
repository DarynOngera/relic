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
  echo "$payload" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//'
}

_db_extract_timestamp() {
  local payload="$1"
  echo "${payload##*,}"
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
