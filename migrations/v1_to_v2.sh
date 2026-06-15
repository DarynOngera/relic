# shellcheck shell=bash
# Example migration from schema v1 to v2.
# In a real deployment this would transform records as needed.

migrate() {
  local db_path="$1"
  local tmp
  tmp=$(mktemp -p "$(dirname "$db_path")")
  if [ -z "$tmp" ]; then
    echo "Error: mktemp failed" >&2
    return 1
  fi

  trap 'rm -f "$tmp"; exit 1' INT TERM

  local line_num=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [ -z "$line" ] && continue

    local record_re='^[^,]+,"[^"]*",[^,]+,[^,]+$'
    if [[ ! "$line" =~ $record_re ]]; then
      echo "Error: migration v1_to_v2: line $line_num: expected 4 CSV fields" >&2
      rm -f "$tmp"
      trap - INT TERM
      return 1
    fi

    local key payload checksum computed
    key="${line%%,*}"
    payload="${line%,*}"
    checksum="${line##*,}"

    computed=$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)
    if [ "$checksum" != "$computed" ]; then
      echo "Error: migration v1_to_v2: line $line_num: checksum mismatch" >&2
      rm -f "$tmp"
      trap - INT TERM
      return 1
    fi

    if [[ "$key" != __* ]]; then
      local value timestamp new_value new_payload new_checksum
      value=$(_db_extract_value "$payload")
      timestamp="${payload##*\",}"
      new_value="v2:$value"
      new_payload="$key,\"$new_value\",$timestamp"
      new_checksum=$(printf '%s' "$new_payload" | sha256sum | cut -d' ' -f1)
      echo "$new_payload,$new_checksum" >> "$tmp"
    else
      echo "$line" >> "$tmp"
    fi
  done < "$db_path"

  if ! mv "$tmp" "$db_path"; then
    rm -f "$tmp"
    trap - INT TERM
    return 1
  fi

  trap - INT TERM
  echo "v1_to_v2 migration complete" >&2
  return 0
}
