# shellcheck shell=bash
# shellcheck source=src/db_utils.sh
# shellcheck source=src/db_storage.sh

_db_ttl_key() {
  local key="$1"
  echo "__ttl__:$key"
}

_db_get_expiry() {
  local key="$1"
  local ttl_key line payload checksum computed value

  ttl_key=$(_db_ttl_key "$key")
  line=$(_db_read_key_lines_for_query "$ttl_key" | tail -n 1)

  [ -z "$line" ] && return 1

  payload="${line%,*}"
  checksum="${line##*,}"
  computed=$(_db_checksum "$payload")
  if [ "$checksum" != "$computed" ]; then
    return 1
  fi

  value=$(_db_extract_value "$payload")
  if [ "$value" = "__deleted__" ]; then
    return 1
  fi

  echo "$value"
}

_db_is_expired() {
  local key="$1"
  local expiry now

  expiry=$(_db_get_expiry "$key") || return 1
  if ! _db_is_integer "$expiry"; then
    return 1
  fi

  now=$(date +%s)
  if [ "$now" -ge "$expiry" ]; then
    return 0
  fi

  return 1
}

db_set_ttl() {
  if [ $# -lt 3 ]; then
    echo "Error: db_set_ttl requires key, value, and TTL seconds" >&2
    return 1
  fi

  _db_validate_key_value "$1" "$2" || return 1

  local ttl="$3"
  if ! _db_is_integer "$ttl" || [ "$ttl" -lt 0 ]; then
    echo "Error: TTL must be a non-negative integer" >&2
    return 1
  fi

  local key="$1" value="$2"
  local expiry now
  now=$(date +%s)
  expiry=$((now + ttl))

  db_begin
  db_set "$key" "$value"
  db_set "$(_db_ttl_key "$key")" "$expiry"
  db_commit
}

db_expire() {
  if [ $# -lt 2 ]; then
    echo "Error: db_expire requires key and TTL seconds" >&2
    return 1
  fi

  _db_validate_key "$1" || return 1

  local ttl="$2"
  if ! _db_is_integer "$ttl" || [ "$ttl" -lt 0 ]; then
    echo "Error: TTL must be a non-negative integer" >&2
    return 1
  fi

  local key="$1" expiry now
  now=$(date +%s)
  expiry=$((now + ttl))

  db_set "$(_db_ttl_key "$key")" "$expiry"
}

db_ttl() {
  if [ $# -ne 1 ]; then
    echo "Error: db_ttl requires exactly one key" >&2
    return 1
  fi

  _db_validate_key "$1" || return 1

  local key="$1" expiry now remaining
  expiry=$(_db_get_expiry "$key") || return 1
  if ! _db_is_integer "$expiry"; then
    return 1
  fi

  now=$(date +%s)
  remaining=$((expiry - now))
  if [ "$remaining" -le 0 ]; then
    return 1
  fi

  echo "$remaining"
}
