#!/usr/bin/env bats

setup() {
  rm -f db db.wal db.lock
  mkdir -p migrations
  # shellcheck source=src/db.sh
  source "$BATS_TEST_DIRNAME/../src/db.sh"
  DB_FILE="$BATS_TEST_DIRNAME/../test_db_fuzz.tmp"
  export db="$DB_FILE"
  export DB_NO_FSYNC=1
  db_init
}

teardown() {
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "db" "db.wal" "db.lock" "$DB_FILE."*
}

_db_rand_key() {
  local len="$1"
  local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
  local str=""
  for ((i = 0; i < len; i++)); do
    local idx=$((RANDOM % ${#chars}))
    str+="${chars:$idx:1}"
  done
  echo "$str"
}

_db_rand_value() {
  local len="$1"
  local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.,:;@#%&*()[]{} "
  local str=""
  for ((i = 0; i < len; i++)); do
    local idx=$((RANDOM % ${#chars}))
    str+="${chars:$idx:1}"
  done
  echo "$str"
}

@test "fuzz random set and get round-trips" {
  local iterations=200
  declare -A expected

  for ((i = 0; i < iterations; i++)); do
    local key value
    key=$(_db_rand_key $((2 + RANDOM % 18)))
    value=$(_db_rand_value $((1 + RANDOM % 50)))
    # Avoid empty value
    if [ -z "$value" ]; then
      value="x"
    fi
    expected[$key]="$value"
    db_set "$key" "$value"
  done

  run db_verify
  [ "$status" -eq 0 ]

  for key in "${!expected[@]}"; do
    local result
    result=$(db_get "$key")
    [ "$result" = "${expected[$key]}" ]
  done
}

@test "fuzz random set delete and get" {
  local iterations=200
  declare -A expected

  for ((i = 0; i < iterations; i++)); do
    local key value
    key=$(_db_rand_key $((2 + RANDOM % 18)))
    value=$(_db_rand_value $((1 + RANDOM % 50)))
    [ -n "$value" ] || value="x"

    local op=$((RANDOM % 3))
    if [ "$op" -eq 0 ]; then
      db_delete "$key"
      unset "expected[$key]"
    else
      expected[$key]="$value"
      db_set "$key" "$value"
    fi
  done

  run db_verify
  [ "$status" -eq 0 ]

  for key in "${!expected[@]}"; do
    local result
    result=$(db_get "$key")
    [ "$result" = "${expected[$key]}" ]
  done

  for key in "${!expected[@]}"; do
    run db_exists "$key"
    [ "$status" -eq 0 ]
  done
}

@test "fuzz values containing commas" {
  local iterations=100
  declare -A expected

  for ((i = 0; i < iterations; i++)); do
    local key value
    key="comma_key_$i"
    value=$(_db_rand_value $((10 + RANDOM % 40)))
    # Ensure at least one comma
    if [[ "$value" != *,* ]]; then
      value="a,$value"
    fi
    expected[$key]="$value"
    db_set "$key" "$value"
  done

  run db_verify
  [ "$status" -eq 0 ]

  for key in "${!expected[@]}"; do
    local result
    result=$(db_get "$key")
    [ "$result" = "${expected[$key]}" ]
  done
}

@test "fuzz mset with random pairs" {
  local batches=20
  declare -A expected

  for ((b = 0; b < batches; b++)); do
    local args=()
    local batch_size=$((2 + RANDOM % 8))
    for ((i = 0; i < batch_size; i++)); do
      local key value
      key=$(_db_rand_key $((3 + RANDOM % 10)))
      value=$(_db_rand_value $((1 + RANDOM % 30)))
      [ -n "$value" ] || value="x"
      args+=("$key" "$value")
      expected[$key]="$value"
    done
    db_mset "${args[@]}"
  done

  run db_verify
  [ "$status" -eq 0 ]

  for key in "${!expected[@]}"; do
    local result
    result=$(db_get "$key")
    [ "$result" = "${expected[$key]}" ]
  done
}
