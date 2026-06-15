# shellcheck shell=bash
# shellcheck source=src/db_utils.sh
# shellcheck source=src/db_ops.sh

_db_base64_available() {
  command -v openssl >/dev/null 2>&1 || command -v base64 >/dev/null 2>&1
}

_db_base64_encode() {
  local value="$1"
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl base64 -A
  elif command -v base64 >/dev/null 2>&1; then
    if ! printf '%s' "$value" | base64 -w0 2>/dev/null; then
      printf '%s' "$value" | base64 | tr -d '\n'
    fi
  else
    echo "Error: base64 or openssl is required" >&2
    return 1
  fi
}

_db_base64_decode() {
  local value="$1"
  if command -v openssl >/dev/null 2>&1; then
    printf '%s' "$value" | openssl base64 -d -A
  elif command -v base64 >/dev/null 2>&1; then
    if ! printf '%s' "$value" | base64 -d 2>/dev/null; then
      printf '%s' "$value" | base64 -D
    fi
  else
    echo "Error: base64 or openssl is required" >&2
    return 1
  fi
}

_db_json_validate() {
  local json="$1"
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    echo "Error: invalid JSON" >&2
    return 1
  fi
}

db_set_json() {
  if [ $# -lt 2 ]; then
    echo "Error: db_set_json requires key and JSON value" >&2
    return 1
  fi
  _db_validate_key "$1" || return 1
  if ! _db_base64_available; then
    echo "Error: base64 or openssl is required for JSON support" >&2
    return 1
  fi

  local key="$1" json="$2"

  if [ -z "$json" ]; then
    echo "Error: JSON value cannot be empty" >&2
    return 1
  fi
  _db_json_validate "$json" || return 1

  local encoded
  encoded=$(_db_base64_encode "$json") || return 1

  db_set "$key" "$encoded"
}

db_get_json() {
  if [ $# -ne 1 ]; then
    echo "Error: db_get_json requires exactly one key" >&2
    return 1
  fi
  _db_validate_key "$1" || return 1
  if ! _db_base64_available; then
    echo "Error: base64 or openssl is required for JSON support" >&2
    return 1
  fi

  local key="$1"
  local encoded json

  encoded=$(db_get "$key") || return 1
  json=$(_db_base64_decode "$encoded") || return 1

  _db_json_validate "$json" || return 1

  echo "$json"
}
