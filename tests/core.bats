#!/usr/bin/env bats

setup() {
  rm -f db
  source "$BATS_TEST_DIRNAME/../src/db.sh"
  DB_FILE="$BATS_TEST_DIRNAME/../test_db.tmp"
  export db="$DB_FILE"
  db_init
}

teardown() {
  rm -f "$DB_FILE" "$DB_FILE.lock" "db"
}

@test "db_init uses custom db path" {
  [ -f "$DB_FILE" ]
  [ ! -f "db" ]
}

@test "db_set stores a value" {
  db_set "key1" "value1"
  result=$(db_get "key1")
  [ "$result" = "value1" ]
}

@test "db_get returns empty for missing key" {
  run db_get "nonexistent"
  [ "$status" -eq 1 ]
}

@test "db_delete marks key as deleted" {
  db_set "key2" "value2"
  db_delete "key2"
  run db_get "key2"
  [ "$status" -eq 1 ]
}

@test "db_set rejects empty key" {
  run db_set "" "value"
  [ "$status" -eq 1 ]
}

@test "db_history shows multiple values" {
  db_set "key3" "val1"
  db_set "key3" "val2"
  result=$(db_history "key3" | wc -l)
  [ "$result" -eq 2 ]
}

@test "db_exists returns 0 for existing key" {
  db_set "key4" "value"
  run db_exists "key4"
  [ "$status" -eq 0 ]
}

@test "db_exists returns 1 for deleted key" {
  db_set "key5" "value"
  db_delete "key5"
  run db_exists "key5"
  [ "$status" -eq 1 ]
}

@test "db_get returns latest value after multiple sets" {
  db_set "key" "val1"
  db_set "key" "val2"
  db_set "key" "val3"
  result=$(db_get "key")
  [ "$result" = "val3" ]
}

@test "db_delete creates tombstone record" {
  db_set "key" "value"
  db_delete "key"
  run db_get "key"
  [ "$status" -eq 1 ]
  result=$(db_history "key" | tail -n 1)
  [[ "$result" == *"[DELETED]"* ]]
}

@test "db_list excludes deleted keys" {
  db_set "a" "1"
  db_set "b" "2"
  db_delete "a"
  result=$(db_list)
  [[ "$result" == *"b"* ]]
  [[ "$result" != *"a"* ]]
}

@test "concurrent db_set writes are atomic" {
  for i in {1..5}; do
    db_set "concurrent_key" "val_$i" &
  done
  wait
  result=$(db_get "concurrent_key")
  [[ "$result" =~ ^val_[0-9]+$ ]]
}

@test "db_set fails when flock unavailable" {
  if command -v flock >/dev/null 2>&1; then
    skip "flock is installed"
  fi
  run db_set "key" "value"
  [ "$status" -eq 1 ]
}

@test "db_get fails when flock unavailable" {
  if command -v flock >/dev/null 2>&1; then
    skip "flock is installed"
  fi
  run db_get "key"
  [ "$status" -eq 1 ]
}
