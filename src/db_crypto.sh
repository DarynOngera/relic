# shellcheck shell=bash
# shellcheck source=src/db_utils.sh

db=${db:-}

_db_crypto_available() {
  command -v openssl >/dev/null 2>&1
}

_db_crypto_enabled() {
  [ -n "${DB_ENCRYPTION_KEY:-}" ]
}

_db_crypto_values_only() {
  [ "${DB_ENCRYPT_VALUES_ONLY:-0}" = "1" ]
}

_db_encrypt_value() {
  local value="$1"
  if ! _db_crypto_available; then
    echo "Error: openssl is required for encryption" >&2
    return 1
  fi
  if [ -z "${DB_ENCRYPTION_KEY:-}" ]; then
    echo "Error: DB_ENCRYPTION_KEY is not set" >&2
    return 1
  fi
  printf '%s' "$value" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$DB_ENCRYPTION_KEY" -base64 -A
}

_db_decrypt_value() {
  local ciphertext="$1"
  if ! _db_crypto_available; then
    echo "Error: openssl is required for encryption" >&2
    return 1
  fi
  if [ -z "${DB_ENCRYPTION_KEY:-}" ]; then
    echo "Error: DB_ENCRYPTION_KEY is not set" >&2
    return 1
  fi
  if ! printf '%s' "$ciphertext" | openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass pass:"$DB_ENCRYPTION_KEY" -base64 -A 2>/dev/null; then
    echo "Error: decryption failed" >&2
    return 1
  fi
}

_db_encrypt_record() {
  local record="$1"
  if ! _db_crypto_available; then
    echo "Error: openssl is required for encryption" >&2
    return 1
  fi
  if [ -z "${DB_ENCRYPTION_KEY:-}" ]; then
    echo "Error: DB_ENCRYPTION_KEY is not set" >&2
    return 1
  fi
  printf '%s' "$record" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass pass:"$DB_ENCRYPTION_KEY" -base64 -A
}

_db_decrypt_record() {
  local ciphertext="$1"
  if ! _db_crypto_available; then
    echo "Error: openssl is required for encryption" >&2
    return 1
  fi
  if [ -z "${DB_ENCRYPTION_KEY:-}" ]; then
    echo "Error: DB_ENCRYPTION_KEY is not set" >&2
    return 1
  fi
  if ! printf '%s' "$ciphertext" | openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass pass:"$DB_ENCRYPTION_KEY" -base64 -A 2>/dev/null; then
    echo "Error: decryption failed" >&2
    return 1
  fi
}

_db_format_record_encrypted_value() {
  local key="$1" value="$2"
  local ciphertext
  ciphertext=$(_db_encrypt_value "$value") || return 1
  _db_format_record "$key" "$ciphertext"
}

_db_extract_value_encrypted() {
  local payload="$1"
  local ciphertext plaintext
  ciphertext=$(_db_extract_value "$payload")
  plaintext=$(_db_decrypt_value "$ciphertext") || return 1
  echo "$plaintext"
}

_db_is_encrypted_record() {
  local line="$1"
  [ "${line%%,*}" = "__enc__" ]
}

_db_encrypt_full_record() {
  local key="$1" value="$2"
  local timestamp plaintext ciphertext wrapper_payload wrapper_checksum

  timestamp=$(_db_timestamp)
  plaintext="$key,\"$value\",$timestamp"
  ciphertext=$(_db_encrypt_record "$plaintext") || return 1
  wrapper_payload="__enc__,\"$ciphertext\",$timestamp"
  wrapper_checksum=$(_db_checksum "$wrapper_payload")
  echo "$wrapper_payload,$wrapper_checksum"
}

db_set_enc() {
  if [ $# -lt 2 ]; then
    echo "Error: db_set_enc requires key and value" >&2
    return 1
  fi
  _db_validate_key_value "$1" "$2" || return 1
  if ! _db_crypto_available; then
    echo "Error: openssl is required for encryption" >&2
    return 1
  fi
  if [ -z "${DB_ENCRYPTION_KEY:-}" ]; then
    echo "Error: DB_ENCRYPTION_KEY is not set" >&2
    return 1
  fi

  local record
  if _db_crypto_values_only; then
    record=$(_db_format_record_encrypted_value "$1" "$2")
  else
    record=$(_db_encrypt_full_record "$1" "$2")
  fi

  (
    _db_lock_exclusive
    _db_write_record "$record"
  ) 200>"${db}.lock"
}

db_get_enc() {
  if [ $# -ne 1 ]; then
    echo "Error: db_get_enc requires exactly one key" >&2
    return 1
  fi
  _db_validate_key "$1" || return 1
  if ! _db_crypto_available; then
    echo "Error: openssl is required for encryption" >&2
    return 1
  fi
  if [ -z "${DB_ENCRYPTION_KEY:-}" ]; then
    echo "Error: DB_ENCRYPTION_KEY is not set" >&2
    return 1
  fi

  local key="$1" encoded ciphertext plaintext
  local line payload inner_key inner_value

  if _db_crypto_values_only; then
    encoded=$(db_get "$key") || return 1
    plaintext=$(_db_decrypt_value "$encoded") || return 1
    echo "$plaintext"
  else
    (
      _db_lock_shared
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        _db_is_encrypted_record "$line" || continue

        payload="${line%,*}"
        ciphertext=$(_db_extract_value "$payload")
        plaintext=$(_db_decrypt_record "$ciphertext") || continue

        inner_key="${plaintext%%,*}"
        if [ "$inner_key" = "$key" ]; then
          inner_value="${plaintext#*,\"}"
          inner_value="${inner_value%\",*}"
          echo "$inner_value"
          return 0
        fi
      done < <(_db_read_all_lines_for_query)
      return 1
    ) 200>"${db}.lock"
  fi
}
