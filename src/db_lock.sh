# shellcheck shell=bash

_db_check_flock() {
  if ! command -v flock >/dev/null 2>&1; then
    echo "Error: flock unavailable" >&2
    return 1
  fi
  return 0
}

_db_lock_exclusive() {
  flock -x 200
}

_db_lock_shared() {
  flock -s 200
}
