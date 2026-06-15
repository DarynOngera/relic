#!/usr/bin/env bats

setup() {
  rm -f db db.wal db.lock
  mkdir -p migrations
  # shellcheck source=src/db.sh
  source "$BATS_TEST_DIRNAME/../src/db.sh"
  DB_FILE="$BATS_TEST_DIRNAME/../test_db_property.tmp"
  export db="$DB_FILE"
  export DB_NO_FSYNC=1
  db_init
}

teardown() {
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "db" "db.wal" "db.lock" "$DB_FILE."*
}

@test "property: db_get returns latest db_set for a key" {
  local iterations=50
  for ((i = 0; i < iterations; i++)); do
    db_set "prop_key" "value_$i"
  done
  local result
  result=$(db_get "prop_key")
  [ "$result" = "value_$((iterations - 1))" ]
}

@test "property: db_delete makes db_get return not found" {
  db_set "prop_key" "value"
  db_delete "prop_key"
  run db_get "prop_key"
  [ "$status" -eq 1 ]
  run db_exists "prop_key"
  [ "$status" -eq 1 ]
}

@test "property: db_count equals number of active unique keys" {
  local keys=("a" "b" "c" "d" "e")
  for key in "${keys[@]}"; do
    db_set "$key" "value_$key"
  done
  db_set "a" "updated_a"
  db_delete "c"

  local count expected
  count=$(db_count)
  expected=4
  [ "$count" -eq "$expected" ]
}

@test "property: db_compact preserves latest values" {
  local iterations=30
  declare -A expected

  for ((i = 0; i < iterations; i++)); do
    db_set "compact_key" "value_$i"
  done
  expected["compact_key"]="value_$((iterations - 1))"

  for ((i = 0; i < 10; i++)); do
    db_set "other_$i" "other_value_$i"
    expected["other_$i"]="other_value_$i"
  done

  db_delete "other_5"
  unset 'expected[other_5]'

  db_compact
  run db_verify
  [ "$status" -eq 0 ]

  for key in "${!expected[@]}"; do
    local result
    result=$(db_get "$key")
    [ "$result" = "${expected[$key]}" ]
  done

  local count
  count=$(db_count)
  [ "$count" -eq ${#expected[@]} ]
}

@test "property: db_sync preserves all writes" {
  local iterations=50
  declare -A expected

  for ((i = 0; i < iterations; i++)); do
    db_set "sync_key_$i" "sync_value_$i"
    expected["sync_key_$i"]="sync_value_$i"
  done

  db_sync

  [ -s "$DB_FILE" ]
  [ ! -s "$DB_FILE.wal" ]

  for key in "${!expected[@]}"; do
    local result
    result=$(db_get "$key")
    [ "$result" = "${expected[$key]}" ]
  done
}

@test "property: transaction rollback restores pre-transaction state" {
  db_set "tx_prop_key" "before"
  db_sync

  db_begin
  db_set "tx_prop_key" "during"
  db_rollback

  local result
  result=$(db_get "tx_prop_key")
  [ "$result" = "before" ]
}

@test "property: transaction commit makes all writes durable" {
  db_begin
  for ((i = 0; i < 20; i++)); do
    db_set "commit_key_$i" "commit_value_$i"
  done
  db_commit

  db_sync

  for ((i = 0; i < 20; i++)); do
    local result
    result=$(db_get "commit_key_$i")
    [ "$result" = "commit_value_$i" ]
  done
}

@test "property: db_history contains all writes for a key" {
  local iterations=10
  for ((i = 0; i < iterations; i++)); do
    db_set "history_key" "value_$i"
  done
  db_delete "history_key"

  local lines
  lines=$(db_history "history_key" | wc -l)
  [ "$lines" -eq $((iterations + 1)) ]
}

@test "property: active keys appear in db_list and deleted keys do not" {
  db_set "active_1" "1"
  db_set "active_2" "2"
  db_set "deleted" "x"
  db_delete "deleted"

  local list
  list=$(db_list)
  [[ "$list" == *"active_1"* ]]
  [[ "$list" == *"active_2"* ]]
  [[ "$list" != *"deleted"* ]]
}
