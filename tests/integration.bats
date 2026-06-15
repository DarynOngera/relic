#!/usr/bin/env bats

setup() {
  rm -f db db.wal db.lock
  mkdir -p migrations
  # shellcheck source=src/db.sh
  source "$BATS_TEST_DIRNAME/../src/db.sh"
  DB_FILE="$BATS_TEST_DIRNAME/../test_db_integration.tmp"
  export db="$DB_FILE"
  export DB_NO_FSYNC=1
  db_init
}

teardown() {
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "db" "db.wal" "db.lock" "$DB_FILE."*
}

@test "concurrent writers on disjoint keys commit all writes" {
  local workers=3
  local per_worker=20
  local pids=()

  for ((w = 0; w < workers; w++)); do
    (
      for ((i = 0; i < per_worker; i++)); do
        db_set "worker_${w}_key_${i}" "value_${w}_${i}"
      done
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  run db_verify
  [ "$status" -eq 0 ]

  local count
  count=$(db_count)
  [ "$count" -eq $((workers * per_worker)) ]

  for ((w = 0; w < workers; w++)); do
    for ((i = 0; i < per_worker; i++)); do
      local result
      result=$(db_get "worker_${w}_key_${i}")
      [ "$result" = "value_${w}_${i}" ]
    done
  done
}

@test "concurrent readers see consistent state while writers run" {
  local writers=2
  local readers=2
  local per_writer=15
  local writer_pids=()
  local reader_pids=()
  local reader_log="${DB_FILE}.reader_log"
  : > "$reader_log"

  for ((w = 0; w < writers; w++)); do
    (
      for ((i = 0; i < per_writer; i++)); do
        db_set "shared_key_${i}" "value_${w}_${i}"
      done
    ) &
    writer_pids+=("$!")
  done

  for ((r = 0; r < readers; r++)); do
    (
      for ((i = 0; i < per_writer; i++)); do
        if db_get "shared_key_${i}" >/dev/null 2>&1; then
          echo "ok" >> "$reader_log"
        else
          echo "missing" >> "$reader_log"
        fi
      done
    ) &
    reader_pids+=("$!")
  done

  for pid in "${writer_pids[@]}" "${reader_pids[@]}"; do
    wait "$pid"
  done

  run db_verify
  [ "$status" -eq 0 ]

  # All keys should eventually be set
  for ((i = 0; i < per_writer; i++)); do
    run db_get "shared_key_${i}"
    [ "$status" -eq 0 ]
  done
}

@test "concurrent mixed set and delete on same key stays consistent" {
  local workers=3
  local iterations=20
  local pids=()

  db_set "hot_key" "initial"

  for ((w = 0; w < workers; w++)); do
    (
      for ((i = 0; i < iterations; i++)); do
        if [ $((i % 2)) -eq 0 ]; then
          db_set "hot_key" "value_${w}_${i}"
        else
          db_delete "hot_key"
        fi
      done
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  run db_verify
  [ "$status" -eq 0 ]

  # Final state must be either a value or deleted, never corrupted
  run db_get "hot_key"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "concurrent db_mset from multiple workers commits all keys" {
  local workers=2
  local per_worker=10
  local pids=()

  for ((w = 0; w < workers; w++)); do
    (
      local args=()
      for ((i = 0; i < per_worker; i++)); do
        args+=("mset_${w}_${i}" "value_${w}_${i}")
      done
      db_mset "${args[@]}"
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  run db_verify
  [ "$status" -eq 0 ]

  local count
  count=$(db_count)
  [ "$count" -eq $((workers * per_worker)) ]
}

@test "concurrent counter increments are atomic" {
  local workers=5
  local iterations=20
  local pids=()

  db_set "counter" "0"

  for ((w = 0; w < workers; w++)); do
    (
      for ((i = 0; i < iterations; i++)); do
        db_incr "counter" >/dev/null
      done
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  local result
  result=$(db_get "counter")
  [ "$result" -eq $((workers * iterations)) ]
}

@test "concurrent conditional updates do not corrupt value" {
  local workers=2
  local iterations=10
  local pids=()

  db_set "cas_key" "0"

  for ((w = 0; w < workers; w++)); do
    (
      for ((i = 0; i < iterations; i++)); do
        local current next
        current=$(db_get "cas_key")
        next=$((current + 1))
        db_update "cas_key" "$current" "$next" >/dev/null 2>&1 || true
      done
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  run db_verify
  [ "$status" -eq 0 ]

  local result
  result=$(db_get "cas_key")
  [ "$result" -le $((workers * iterations)) ]
  [ "$result" -ge 0 ]
}
