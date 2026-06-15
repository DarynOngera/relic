# shellcheck shell=bash
# shellcheck source=src/db_tx.sh

_db_check_flock() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi
  return 0
}

_db_lock_exclusive() {
  if _db_tx_active; then
    return 0
  fi
  local timeout="${DB_LOCK_TIMEOUT:-10}"
  flock -w "$timeout" -x 200
}

_db_lock_shared() {
  if _db_tx_active; then
    return 0
  fi
  local timeout="${DB_LOCK_TIMEOUT:-10}"
  flock -w "$timeout" -s 200
}
