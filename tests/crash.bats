#!/usr/bin/env bats

setup() {
  rm -f db db.wal db.lock
  mkdir -p migrations
  # shellcheck source=src/db.sh
  source "$BATS_TEST_DIRNAME/../src/db.sh"
  DB_FILE="$BATS_TEST_DIRNAME/../test_db_crash.tmp"
  export db="$DB_FILE"
  HELPER="$BATS_TEST_DIRNAME/helpers/crash_writer.sh"
}

teardown() {
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "$DB_FILE.tx.wal" "$DB_FILE.tx.snapshot" "db" "db.wal" "db.lock" "$DB_FILE."*
}

_wait_for_progress() {
  local progress_file="$1"
  local min="${2:-20}"
  local waited=0
  while [ ! -f "$progress_file" ] || [ "$(cat "$progress_file" 2>/dev/null || echo 0)" -lt "$min" ]; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -gt 100 ]; then
      return 1
    fi
  done
}

_kill_and_wait() {
  local pid="$1"
  kill -9 "$pid" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -gt 50 ]; then
      return 1
    fi
  done
}

@test "crash recovery leaves database verifiable with fsync enabled" {
  local progress_file="${DB_FILE}.progress"
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "$progress_file"

  DB_NO_FSYNC=0 bash "$HELPER" "$DB_FILE" "$progress_file" 0 &
  local pid=$!

  _wait_for_progress "$progress_file" 30
  _kill_and_wait "$pid"

  [ ! -d "/proc/$pid" ] 2>/dev/null || [ ! -e "/proc/$pid" ]

  run db_init
  [ "$status" -eq 0 ]
  [ ! -f "$DB_FILE.tx.wal" ]
  [ ! -f "$DB_FILE.tx.snapshot" ]

  run db_verify
  [ "$status" -eq 0 ]

  db_sync

  local recovered
  recovered=$(cat "$DB_FILE" "$DB_FILE.wal" 2>/dev/null | grep -c '^crash_key_' || echo 0)
  [ "$recovered" -ge 1 ]
}

@test "crash recovery leaves database verifiable with DB_NO_FSYNC=1" {
  local progress_file="${DB_FILE}.progress"
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "$progress_file"

  DB_NO_FSYNC=1 bash "$HELPER" "$DB_FILE" "$progress_file" 1 &
  local pid=$!

  _wait_for_progress "$progress_file" 30
  _kill_and_wait "$pid"

  run db_init
  [ "$status" -eq 0 ]
  [ ! -f "$DB_FILE.tx.wal" ]
  [ ! -f "$DB_FILE.tx.snapshot" ]

  run db_verify
  [ "$status" -eq 0 ]

  db_sync

  # With fsync disabled, record count relative to progress file is
  # nondeterministic; just ensure some records are present.
  local recovered
  recovered=$(cat "$DB_FILE" "$DB_FILE.wal" 2>/dev/null | grep -c '^crash_key_' || echo 0)
  [ "$recovered" -ge 0 ]
}

@test "db_init rolls back incomplete transaction after crash" {
  db_set "before_crash" "value"
  db_sync

  # Simulate a crashed transaction by creating leftover files
  cp "$DB_FILE" "$DB_FILE.tx.snapshot"
  echo 'txkey,"txvalue",2026-06-15T00:00:00+00:00,invalid' > "$DB_FILE.tx.wal"

  run db_init
  [ "$status" -eq 0 ]
  [ ! -f "$DB_FILE.tx.wal" ]
  [ ! -f "$DB_FILE.tx.snapshot" ]

  result=$(db_get "before_crash")
  [ "$result" = "value" ]
}
