#!/usr/bin/env bats

setup() {
  rm -f db db.wal db.lock
  mkdir -p migrations
  # shellcheck source=src/db.sh
  source "$BATS_TEST_DIRNAME/../src/db.sh"
  DB_FILE="$BATS_TEST_DIRNAME/../test_db_stress.tmp"
  export db="$DB_FILE"
  export DB_NO_FSYNC=1
  STRESS_COUNT="${STRESS_COUNT:-500}"
  STRESS_READ_KEYS="${STRESS_READ_KEYS:-50}"

  if [ "${RUN_STRESS_TESTS:-0}" != "1" ]; then
    skip "Stress tests disabled. Set RUN_STRESS_TESTS=1 to run."
  fi

  db_init
}

teardown() {
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "db" "db.wal" "db.lock" "$DB_FILE."*
}

_db_now_ms() {
  date +%s%N | awk '{print int($1 / 1000000)}'
}

@test "stress: insert $STRESS_COUNT records" {
  local start end elapsed ops_per_sec
  start=$(_db_now_ms)

  for ((i = 0; i < STRESS_COUNT; i++)); do
    db_set "stress_key_$i" "stress_value_$i"
  done

  end=$(_db_now_ms)
  elapsed=$((end - start))
  ops_per_sec=$(awk -v c="$STRESS_COUNT" -v e="$elapsed" 'BEGIN {printf "%.2f", c / (e / 1000)}')
  echo "insert: $STRESS_COUNT records in ${elapsed}ms ($ops_per_sec ops/sec)"

  run db_verify
  [ "$status" -eq 0 ]

  local count
  count=$(db_count)
  [ "$count" -eq "$STRESS_COUNT" ]
}

@test "stress: read $STRESS_READ_KEYS records" {
  for ((i = 0; i < STRESS_COUNT; i++)); do
    db_set "stress_key_$i" "stress_value_$i"
  done
  db_sync

  local start end elapsed ops_per_sec
  start=$(_db_now_ms)

  for ((i = 0; i < STRESS_READ_KEYS; i++)); do
    local result
    result=$(db_get "stress_key_$i")
    [ "$result" = "stress_value_$i" ]
  done

  end=$(_db_now_ms)
  elapsed=$((end - start))
  ops_per_sec=$(awk -v c="$STRESS_READ_KEYS" -v e="$elapsed" 'BEGIN {printf "%.2f", c / (e / 1000)}')
  echo "read: $STRESS_READ_KEYS records from $STRESS_COUNT in ${elapsed}ms ($ops_per_sec ops/sec)"
}

@test "stress: delete half of $STRESS_COUNT records" {
  for ((i = 0; i < STRESS_COUNT; i++)); do
    db_set "stress_key_$i" "stress_value_$i"
  done

  local start end elapsed ops_per_sec
  start=$(_db_now_ms)

  for ((i = 0; i < STRESS_COUNT; i += 2)); do
    db_delete "stress_key_$i"
  done

  end=$(_db_now_ms)
  elapsed=$((end - start))
  local delete_count=$(( (STRESS_COUNT + 1) / 2 ))
  ops_per_sec=$(awk -v c="$delete_count" -v e="$elapsed" 'BEGIN {printf "%.2f", c / (e / 1000)}')
  echo "delete: $delete_count records in ${elapsed}ms ($ops_per_sec ops/sec)"

  local count expected
  count=$(db_count)
  expected=$((STRESS_COUNT - delete_count))
  [ "$count" -eq "$expected" ]
}

@test "stress: compact after $STRESS_COUNT overwrites" {
  db_set "stress_key" "initial"

  for ((i = 0; i < STRESS_COUNT; i++)); do
    db_set "stress_key" "value_$i"
  done

  local start end elapsed
  start=$(_db_now_ms)
  db_compact
  end=$(_db_now_ms)
  elapsed=$((end - start))
  echo "compact: $STRESS_COUNT overwrites in ${elapsed}ms"

  run db_verify
  [ "$status" -eq 0 ]

  local result count
  result=$(db_get "stress_key")
  [ "$result" = "value_$((STRESS_COUNT - 1))" ]
  count=$(grep -c '^stress_key,"' "$DB_FILE")
  [ "$count" -eq 1 ]
}
