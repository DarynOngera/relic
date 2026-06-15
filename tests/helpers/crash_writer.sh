#!/bin/bash
# shellcheck shell=bash
# Helper process for crash-recovery tests.
# Usage: crash_writer.sh <db_base_path> <progress_file> [DB_NO_FSYNC]

set -uo pipefail

DB_PATH="${1:-}"
PROGRESS_FILE="${2:-}"
DB_NO_FSYNC="${3:-0}"

if [ -z "$DB_PATH" ] || [ -z "$PROGRESS_FILE" ]; then
  echo "Usage: $0 <db_base_path> <progress_file> [DB_NO_FSYNC]" >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=src/db.sh
source "$SCRIPT_DIR/src/db.sh"

db="$DB_PATH"
export DB_NO_FSYNC

db_init >/dev/null 2>&1

i=0
while true; do
  i=$((i + 1))
  if db_set "crash_key_$i" "crash_value_$i" >/dev/null 2>&1; then
    printf '%s\n' "$i" > "$PROGRESS_FILE.tmp"
    mv "$PROGRESS_FILE.tmp" "$PROGRESS_FILE"
  fi
  sleep 0.001 2>/dev/null || sleep 1
done
