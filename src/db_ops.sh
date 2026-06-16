# shellcheck shell=bash
# shellcheck source=src/db_utils.sh
# shellcheck source=src/db_lock.sh
# shellcheck source=src/db_storage.sh
# shellcheck source=src/db_tx.sh

db=${db:-}

db_set() {
  _db_validate_key_value "$1" "$2" || return 1
  _db_check_flock || return 1

  local record
  record=$(_db_format_record "$1" "$2")

  (
    _db_lock_exclusive
    _db_write_record "$record"
  ) 200>"${db}.lock"
  _db_fire_trigger_if_user_key "set" "$1" "$2"

  return 0
}

db_delete() {
  _db_validate_key "$1" || return 1
  _db_check_flock || return 1

  local record
  record=$(_db_format_record "$1" "__deleted__")

  (
    _db_lock_exclusive
    _db_write_record "$record"
  ) 200>"${db}.lock"
  _db_fire_trigger_if_user_key "delete" "$1" "__deleted__"

  return 0
}

db_get() {
  _db_check_flock || return 1
  _db_validate_key "$1" || return 1

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local line payload checksum computed value
    line=$(_db_read_key_lines_for_query "$1" | tail -n 1)

    if [ -z "$line" ]; then
      return 1
    fi

    payload="${line%,*}"
    checksum="${line##*,}"
    computed=$(_db_checksum "$payload")
    if [ "$checksum" != "$computed" ]; then
      echo "Error: checksum mismatch" >&2
      return 1
    fi

    value=$(_db_extract_value "$payload")
    if [ "$value" = "__deleted__" ]; then
      return 1
    fi
    if _db_is_expired "$1"; then
      return 1
    fi
    echo "$value"
  ) 200>"${db}.lock"
}

db_history() {
  _db_check_flock || return 1
  _db_validate_key "$1" || return 1

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local has_error=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue

      local payload checksum computed value timestamp
      payload="${line%,*}"
      checksum="${line##*,}"
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch" >&2
        has_error=1
        break
      fi

      value=$(_db_extract_value "$payload")
      timestamp=$(_db_extract_timestamp "$payload")
      if [ "$value" = "__deleted__" ]; then
        echo "[DELETED] @ $timestamp"
      else
        echo "$value @ $timestamp"
      fi
    done < <(_db_read_key_lines_for_query "$1")

    return "$has_error"
  ) 200>"${db}.lock"
}

db_exists() {
  _db_check_flock || return 1
  _db_validate_key "$1" || return 1

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local line payload checksum computed value
    line=$(_db_read_key_lines_for_query "$1" | tail -n 1)

    if [ -z "$line" ]; then
      return 1
    fi

    payload="${line%,*}"
    checksum="${line##*,}"
    computed=$(_db_checksum "$payload")
    if [ "$checksum" != "$computed" ]; then
      echo "Error: checksum mismatch" >&2
      return 1
    fi

    value=$(_db_extract_value "$payload")
    if [ "$value" = "__deleted__" ]; then
      return 1
    fi
    if _db_is_expired "$1"; then
      return 1
    fi
    return 0
  ) 200>"${db}.lock"
}

db_list() {
  _db_check_flock || return 1

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
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

    done < <(_db_read_all_lines_for_query)

    if [ "$has_error" -eq 1 ]; then
      return 1
    fi

    for key in "${!seen[@]}"; do
      [ -z "$key" ] && continue
      _db_is_system_key "$key" && continue
      local line payload value
      line=$(_db_read_key_lines_for_query "$key" | tail -n 1)
      payload="${line%,*}"
      value=$(_db_extract_value "$payload")
      if [ "$value" != "__deleted__" ] && ! _db_is_expired "$key"; then
        echo "$key"
      fi
    done

    return 0
  ) 200>"${db}.lock"
}

db_mset() {
  if [ $# -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
    echo "Error: db_mset requires an even number of key-value arguments" >&2
    return 1
  fi
  _db_check_flock || return 1

  local records=() keys=() values=()
  while [ $# -gt 0 ]; do
    _db_validate_key_value "$1" "$2" || return 1
    local record
    record=$(_db_format_record "$1" "$2")
    records+=("$record")
    keys+=("$1")
    values+=("$2")
    shift 2
  done

  (
    _db_lock_exclusive
    if [ ${#records[@]} -gt 0 ]; then
      local batch_size="${DB_BATCH_SIZE:-100}"
      local i=0
      while [ $i -lt ${#records[@]} ]; do
        printf '%s\n' "${records[@]:i:batch_size}" >> "$db.wal"
        i=$((i + batch_size))
      done
    fi
  ) 200>"${db}.lock"

  local k=0
  while [ $k -lt ${#keys[@]} ]; do
    _db_fire_trigger_if_user_key "set" "${keys[$k]}" "${values[$k]}"
    k=$((k + 1))
  done

  return 0
}

db_mget() {
  if [ $# -eq 0 ]; then
    echo "Error: db_mget requires at least one key" >&2
    return 1
  fi
  _db_check_flock || return 1

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
    fi

    local key line payload checksum computed value
    for key in "$@"; do
      _db_validate_key "$key" || continue
      line=$(_db_read_key_lines_for_query "$key" | tail -n 1)
      [ -z "$line" ] && continue

      payload="${line%,*}"
      checksum="${line##*,}"
      computed=$(_db_checksum "$payload")
      if [ "$checksum" != "$computed" ]; then
        echo "Error: checksum mismatch" >&2
        return 1
      fi

      value=$(_db_extract_value "$payload")
      if [ "$value" != "__deleted__" ] && ! _db_is_expired "$key"; then
        printf '%s\t%s\n' "$key" "$value"
      fi
    done

    return 0
  ) 200>"${db}.lock"
}

_db_adjust_counter_body() {
  local key="$1" delta="$2"
  local line payload checksum computed value new_value record

  line=$(_db_read_key_lines_for_query "$key" | tail -n 1)

  if [ -z "$line" ]; then
    echo "Error: key does not exist" >&2
    return 1
  fi

  payload="${line%,*}"
  checksum="${line##*,}"
  computed=$(_db_checksum "$payload")
  if [ "$checksum" != "$computed" ]; then
    echo "Error: checksum mismatch" >&2
    return 1
  fi

  value=$(_db_extract_value "$payload")
  if [ "$value" = "__deleted__" ]; then
    echo "Error: key does not exist" >&2
    return 1
  fi
  if _db_is_expired "$key"; then
    echo "Error: key does not exist" >&2
    return 1
  fi

  if ! _db_is_integer "$value"; then
    echo "Error: value is not an integer" >&2
    return 1
  fi

  new_value=$(( value + delta ))
  record=$(_db_format_record "$key" "$new_value")
  _db_write_record "$record"
  echo "$new_value"
}

_db_adjust_counter() {
  local key="$1" delta="$2"

  if _db_tx_active; then
    _db_adjust_counter_body "$key" "$delta"
    return 0
  fi

  (
    _db_lock_exclusive
    _db_adjust_counter_body "$key" "$delta"
  ) 200>"${db}.lock"
}

db_incr() {
  _db_validate_key "$1" || return 1
  _db_check_flock || return 1

  local amount=1
  if [ $# -ge 2 ]; then
    amount="$2"
    if ! _db_is_integer "$amount"; then
      echo "Error: increment amount must be an integer" >&2
      return 1
    fi
  fi

  local result status
  result=$(_db_adjust_counter "$1" "$amount")
  status=$?
  if [ "$status" -eq 0 ]; then
    _db_fire_trigger_if_user_key "set" "$1" "$result"
    echo "$result"
  fi
  return "$status"
}

db_decr() {
  _db_validate_key "$1" || return 1
  _db_check_flock || return 1

  local amount=1
  if [ $# -ge 2 ]; then
    amount="$2"
    if ! _db_is_integer "$amount"; then
      echo "Error: decrement amount must be an integer" >&2
      return 1
    fi
  fi

  local result status
  result=$(_db_adjust_counter "$1" "-$amount")
  status=$?
  if [ "$status" -eq 0 ]; then
    _db_fire_trigger_if_user_key "set" "$1" "$result"
    echo "$result"
  fi
  return "$status"
}

db_update() {
  if [ $# -lt 3 ]; then
    echo "Error: db_update requires key, expected value, and new value" >&2
    return 1
  fi
  _db_validate_key "$1" || return 1
  if [ -z "$2" ] || [ -z "$3" ]; then
    echo "Error: expected and new value cannot be empty" >&2
    return 1
  fi
  if [[ "$2" == *\"* ]] || [[ "$3" == *\"* ]]; then
    echo "Error: value cannot contain quotes" >&2
    return 1
  fi
  _db_check_flock || return 1

  local key="$1" expected="$2" new_value="$3"

  local status=0
  if _db_tx_active; then
    _db_update_body "$key" "$expected" "$new_value"
    status=$?
  else
    (
      _db_lock_exclusive
      _db_update_body "$key" "$expected" "$new_value"
    ) 200>"${db}.lock"
    status=$?
  fi

  if [ "$status" -eq 0 ]; then
    _db_fire_trigger_if_user_key "set" "$key" "$new_value"
  fi
  return "$status"
}

_db_update_body() {
  local key="$1" expected="$2" new_value="$3"
  local line payload checksum computed current

  line=$(_db_read_key_lines_for_query "$key" | tail -n 1)

  if [ -z "$line" ]; then
    echo "Error: key does not exist" >&2
    return 1
  fi

  payload="${line%,*}"
  checksum="${line##*,}"
  computed=$(_db_checksum "$payload")
  if [ "$checksum" != "$computed" ]; then
    echo "Error: checksum mismatch" >&2
    return 1
  fi

  current=$(_db_extract_value "$payload")
  if [ "$current" = "__deleted__" ]; then
    echo "Error: key does not exist" >&2
    return 1
  fi
  if _db_is_expired "$key"; then
    echo "Error: key does not exist" >&2
    return 1
  fi

  if [ "$current" != "$expected" ]; then
    echo "Error: current value does not match expected value" >&2
    return 1
  fi

  local record
  record=$(_db_format_record "$key" "$new_value")
  _db_write_record "$record"
  return 0
}

db_keys() {
  if [ $# -ne 1 ]; then
    echo "Error: db_keys requires exactly one pattern" >&2
    return 1
  fi
  _db_check_flock || return 1

  local pattern="$1"

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
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

    done < <(_db_read_all_lines_for_query)

    if [ "$has_error" -eq 1 ]; then
      return 1
    fi

    for key in "${!seen[@]}"; do
      [ -z "$key" ] && continue
      _db_is_system_key "$key" && continue
      # shellcheck disable=SC2053
      [[ "$key" != $pattern ]] && continue
      local line payload value
      line=$(_db_read_key_lines_for_query "$key" | tail -n 1)
      payload="${line%,*}"
      value=$(_db_extract_value "$payload")
      if [ "$value" != "__deleted__" ] && ! _db_is_expired "$key"; then
        echo "$key"
      fi
    done

    return 0
  ) 200>"${db}.lock"
}

db_search() {
  if [ $# -ne 1 ]; then
    echo "Error: db_search requires exactly one search term" >&2
    return 1
  fi
  _db_check_flock || return 1

  local term="$1"
  if [ -z "$term" ]; then
    echo "Error: search term cannot be empty" >&2
    return 1
  fi

  (
    _db_lock_shared
    if [ ! -f "$db" ] && [ ! -f "$db.wal" ]; then
      return 1
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

    done < <(_db_read_all_lines_for_query)

    if [ "$has_error" -eq 1 ]; then
      return 1
    fi

    for key in "${!seen[@]}"; do
      [ -z "$key" ] && continue
      _db_is_system_key "$key" && continue
      local line payload latest_value
      line=$(_db_read_key_lines_for_query "$key" | tail -n 1)
      payload="${line%,*}"
      latest_value=$(_db_extract_value "$payload")
      if [ "$latest_value" != "__deleted__" ] && ! _db_is_expired "$key" && [[ "$latest_value" == *"$term"* ]]; then
        echo "$key"
      fi
    done

    return 0
  ) 200>"${db}.lock"
}
