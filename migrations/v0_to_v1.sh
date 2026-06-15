# shellcheck shell=bash
# Migration from legacy 3-field format to 4-field format with SHA256 checksums.

migrate() {
  local db_path="$1"
  local tmp
  tmp=$(mktemp -p "$(dirname "$db_path")")
  if [ -z "$tmp" ]; then
    echo "Error: mktemp failed" >&2
    return 1
  fi

  trap 'rm -f "$tmp"; exit 1' INT TERM

  local line_num=0 migrated=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    [ -z "$line" ] && continue

    local record3_re='^[^,]+,"[^"]*",[^,]+$'
    local record4_re='^[^,]+,"[^"]*",[^,]+,[^,]+$'
    if [[ "$line" =~ $record4_re ]]; then
      echo "$line" >> "$tmp"
      migrated=$((migrated + 1))
    elif [[ "$line" =~ $record3_re ]]; then
      local checksum
      checksum=$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)
      echo "$line,$checksum" >> "$tmp"
      migrated=$((migrated + 1))
    else
      echo "Error: v0_to_v1 line $line_num: invalid format (expected 3 or 4 CSV fields)" >&2
      rm -f "$tmp"
      trap - INT TERM
      return 1
    fi
  done < "$db_path"

  if ! mv "$tmp" "$db_path"; then
    rm -f "$tmp"
    trap - INT TERM
    return 1
  fi

  trap - INT TERM
  echo "v0_to_v1 migration complete: $migrated records migrated" >&2
  return 0
}
