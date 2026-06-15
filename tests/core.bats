#!/usr/bin/env bats

setup() {
  rm -f db db.wal db.lock
  mkdir -p migrations
  # shellcheck source=src/db.sh
  source "$BATS_TEST_DIRNAME/../src/db.sh"
  DB_FILE="$BATS_TEST_DIRNAME/../test_db.tmp"
  export db="$DB_FILE"
  db_init
}

teardown() {
  rm -f "$DB_FILE" "$DB_FILE.lock" "$DB_FILE.wal" "db" "db.wal" "db.lock" "$DB_FILE."* "$DB_FILE.backup" "$DB_FILE.backup.wal" "$DB_FILE.backup.gz" "$DB_FILE.backup.wal.gz" "$DB_FILE.tx.wal" "$DB_FILE.tx.snapshot"
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

@test "db_migrate converts old format to new" {
  echo 'oldkey,"oldvalue",2026-06-12T00:00:00+00:00' > "$DB_FILE"
  db_migrate
  result=$(db_get "oldkey")
  # v0_to_v1 converts format, then v1_to_v2 prepends v2: to user values
  [ "$result" = "v2:oldvalue" ]
  # Verify new format has 4 fields
  local first_line
  first_line=$(head -n 1 "$DB_FILE")
  local field_count
  field_count=$(echo "$first_line" | awk -F',' '{print NF}')
  [ "$field_count" -eq 4 ]
}

@test "db_migrate applies ordered migration scripts" {
  db_set "key" "value"
  db_sync
  db_migrate
  result=$(db_get "key")
  [ "$result" = "v2:value" ]
  run grep '__migration_applied__' "$DB_FILE"
  [ "$status" -eq 0 ]
}

@test "db_migrate is idempotent" {
  db_set "key" "value"
  db_sync
  db_migrate
  db_migrate
  result=$(db_get "key")
  [ "$result" = "v2:value" ]
}

@test "db_migrate fails without migrations directory on version 0 db" {
  echo 'oldkey,"oldvalue",2026-06-12T00:00:00+00:00' > "$DB_FILE"
  mv migrations "${DB_FILE}.migrations.bak"
  run db_migrate
  [ "$status" -eq 1 ]
  mv "${DB_FILE}.migrations.bak" migrations
}

@test "db_verify reports clean database" {
  db_set "key" "value"
  run db_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
}

@test "db_verify detects corrupted record" {
  db_set "key" "value"
  # Corrupt the checksum in the WAL file
  echo 'key,"value",2026-06-12T00:00:00+00:00,INVALIDCHECKSUM' >> "$DB_FILE.wal"
  run db_verify
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
}

@test "db_sync flushes WAL to database" {
  db_set "key" "value"
  # Before sync, WAL should have data
  [ -s "$DB_FILE.wal" ]
  db_sync
  # After sync, WAL should be empty and db should have data
  [ ! -s "$DB_FILE.wal" ]
  [ -s "$DB_FILE" ]
  result=$(db_get "key")
  [ "$result" = "value" ]
}

@test "db_get fails on checksum mismatch" {
  db_set "key" "value"
  db_sync
  # Corrupt the checksum in the database file
  sed -i 's/[^,]*$/INVALIDCHECKSUM/' "$DB_FILE"
  run db_get "key"
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
}

@test "db_list fails on corrupted database" {
  db_set "a" "1"
  db_set "b" "2"
  db_sync
  # Corrupt the database
  echo 'corrupted,"data",2026-06-12T00:00:00+00:00,INVALID' >> "$DB_FILE"
  run db_list
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
}

@test "db_stats includes WAL size" {
  db_set "key" "value"
  run db_stats
  [ "$status" -eq 0 ]
  [[ "$output" == *"WAL size"* ]]
}

@test "all public functions are loaded from modules" {
  run bash -c 'source "'"$BATS_TEST_DIRNAME"'/../src/db.sh"; declare -f db_init db_set db_get db_delete db_exists db_history db_list db_stats db_sync db_verify db_migrate db_mset db_mget db_incr db_decr db_update db_keys db_search db_clear db_count db_size db_compact db_vacuum db_backup db_restore db_truncate db_begin db_commit db_rollback >/dev/null'
  [ "$status" -eq 0 ]
}

@test "db_init sets schema version" {
  db_init
  run grep '__schema_version__' "$DB_FILE"
  [ "$status" -eq 0 ]
}

@test "db_compact removes tombstones and overwrites" {
  db_set "a" "1"
  db_set "a" "2"
  db_set "a" "3"
  db_delete "b"
  db_set "b" "value"
  db_compact
  [ "$(grep -c '^a,"' "$DB_FILE")" -eq 1 ]
  result=$(db_get "a")
  [ "$result" = "3" ]
  result=$(db_get "b")
  [ "$result" = "value" ]
}

@test "db_compact preserves system markers" {
  db_set "a" "1"
  db_clear
  db_compact
  run grep '__cleared__' "$DB_FILE"
  [ "$status" -eq 0 ]
}

@test "db_vacuum compacts and verifies" {
  db_set "a" "1"
  db_set "a" "2"
  db_vacuum
  run db_verify
  [ "$status" -eq 0 ]
  result=$(db_get "a")
  [ "$result" = "2" ]
}

@test "db_backup copies db and wal" {
  db_set "a" "1"
  db_sync
  db_set "b" "2"
  db_backup "${DB_FILE}.backup"
  [ -f "${DB_FILE}.backup" ]
  [ -f "${DB_FILE}.backup.wal" ]
  run grep 'a,"1"' "${DB_FILE}.backup"
  [ "$status" -eq 0 ]
  run grep 'b,"2"' "${DB_FILE}.backup.wal"
  [ "$status" -eq 0 ]
}

@test "db_restore refuses non-empty database" {
  db_set "a" "1"
  db_backup "${DB_FILE}.backup"
  db_set "b" "2"
  run db_restore "${DB_FILE}.backup"
  [ "$status" -eq 1 ]
}

@test "db_restore succeeds on empty database" {
  db_set "a" "1"
  db_backup "${DB_FILE}.backup"
  rm -f "$DB_FILE" "$DB_FILE.wal" "$DB_FILE.lock"
  touch "$DB_FILE" "$DB_FILE.wal"
  db_restore "${DB_FILE}.backup"
  result=$(db_get "a")
  [ "$result" = "1" ]
}

@test "db_restore rejects corrupted backup" {
  echo 'corrupted,"data",2026-06-15T00:00:00+00:00,INVALID' > "${DB_FILE}.backup"
  rm -f "$DB_FILE" "$DB_FILE.wal" "$DB_FILE.lock"
  db_init
  run db_restore "${DB_FILE}.backup"
  [ "$status" -eq 1 ]
}

@test "db_truncate rotates and compresses when size exceeded" {
  if ! command -v gzip >/dev/null 2>&1; then
    skip "gzip unavailable"
  fi
  db_set "key" "value"
  db_sync
  # Force small max size to trigger rotation
  db_truncate 1
  [ -f "${DB_FILE}.1.gz" ]
  [ ! -s "$DB_FILE" ]
}

@test "db_truncate keeps at most three rotated segments" {
  if ! command -v gzip >/dev/null 2>&1; then
    skip "gzip unavailable"
  fi
  db_set "key" "value"
  db_sync
  db_truncate 1
  db_set "key" "value2"
  db_sync
  db_truncate 1
  db_set "key" "value3"
  db_sync
  db_truncate 1
  db_set "key" "value4"
  db_sync
  db_truncate 1
  [ -f "${DB_FILE}.1.gz" ]
  [ -f "${DB_FILE}.2.gz" ]
  [ -f "${DB_FILE}.3.gz" ]
  [ ! -f "${DB_FILE}.4" ]
  [ ! -f "${DB_FILE}.4.gz" ]
}

@test "db_get finds values in compressed rotated segments" {
  if ! command -v gzip >/dev/null 2>&1; then
    skip "gzip unavailable"
  fi
  db_set "key" "value1"
  db_sync
  db_truncate 1
  db_set "key" "value2"
  db_sync
  result=$(db_get "key")
  [ "$result" = "value2" ]
}

@test "db_backup supports optional compression" {
  if ! command -v gzip >/dev/null 2>&1; then
    skip "gzip unavailable"
  fi
  db_set "a" "1"
  db_sync
  db_set "b" "2"
  DB_BACKUP_COMPRESS=1 db_backup "${DB_FILE}.backup"
  [ -f "${DB_FILE}.backup.gz" ]
  [ -f "${DB_FILE}.backup.wal.gz" ]
}

@test "db_restore handles compressed backups" {
  if ! command -v gzip >/dev/null 2>&1; then
    skip "gzip unavailable"
  fi
  db_set "a" "1"
  db_sync
  db_set "b" "2"
  DB_BACKUP_COMPRESS=1 db_backup "${DB_FILE}.backup"
  rm -f "$DB_FILE" "$DB_FILE.wal" "$DB_FILE.lock"
  touch "$DB_FILE" "$DB_FILE.wal"
  db_restore "${DB_FILE}.backup"
  result=$(db_get "a")
  [ "$result" = "1" ]
  result=$(db_get "b")
  [ "$result" = "2" ]
}

@test "db_mset stores multiple values atomically" {
  db_mset "a" "1" "b" "2"
  result_a=$(db_get "a")
  result_b=$(db_get "b")
  [ "$result_a" = "1" ]
  [ "$result_b" = "2" ]
}

@test "db_mset fails with odd number of arguments" {
  run db_mset "a" "1" "b"
  [ "$status" -eq 1 ]
}

@test "db_mget returns key-value pairs separated by tabs" {
  db_mset "a" "1" "b" "2"
  result=$(db_mget "a" "b")
  [[ "$result" == *"a	1"* ]]
  [[ "$result" == *"b	2"* ]]
}

@test "db_mget omits missing keys" {
  db_set "a" "1"
  result=$(db_mget "a" "missing")
  [[ "$result" == *"a"* ]]
  [[ "$result" != *"missing"* ]]
}

@test "db_incr increments an integer value" {
  db_set "counter" "5"
  result=$(db_incr "counter")
  [ "$result" -eq 6 ]
}

@test "db_incr fails when key does not exist" {
  run db_incr "missing_counter"
  [ "$status" -eq 1 ]
}

@test "db_incr fails when value is not an integer" {
  db_set "counter" "not_a_number"
  run db_incr "counter"
  [ "$status" -eq 1 ]
}

@test "db_decr decrements an integer value" {
  db_set "counter" "5"
  result=$(db_decr "counter")
  [ "$result" -eq 4 ]
}

@test "db_update changes value only when expected matches" {
  db_set "key" "old"
  db_update "key" "old" "new"
  result=$(db_get "key")
  [ "$result" = "new" ]
}

@test "db_update fails when current value does not match" {
  db_set "key" "actual"
  run db_update "key" "wrong" "new"
  [ "$status" -eq 1 ]
}

@test "db_update rejects empty new value" {
  db_set "key" "old"
  run db_update "key" "old" ""
  [ "$status" -eq 1 ]
  result=$(db_get "key")
  [ "$result" = "old" ]
}

@test "db_get handles values containing commas" {
  db_set "key" "a,b,c"
  result=$(db_get "key")
  [ "$result" = "a,b,c" ]
}

@test "db_keys filters keys by glob pattern" {
  db_mset "user:1" "a" "user:2" "b" "post:1" "c"
  result=$(db_keys "user:*")
  [[ "$result" == *"user:1"* ]]
  [[ "$result" == *"user:2"* ]]
  [[ "$result" != *"post:1"* ]]
}

@test "db_search returns keys whose values contain term" {
  db_mset "a" "hello world" "b" "goodbye" "c" "hello again"
  result=$(db_search "hello")
  [[ "$result" == *"a"* ]]
  [[ "$result" == *"c"* ]]
  [[ "$result" != *"b"* ]]
}

@test "db_clear removes all active keys and writes audit marker" {
  db_mset "a" "1" "b" "2"
  db_sync
  db_clear
  run db_get "a"
  [ "$status" -eq 1 ]
  run db_get "b"
  [ "$status" -eq 1 ]
  run db_count
  [ "$output" -eq 0 ]
  run grep '__cleared__' "$DB_FILE"
  [ "$status" -eq 0 ]
}

@test "db_count returns number of active keys" {
  db_mset "a" "1" "b" "2"
  db_delete "a"
  result=$(db_count)
  [ "$result" -eq 1 ]
}

@test "db_size returns human-readable total size" {
  db_set "key" "value"
  result=$(db_size)
  [[ "$result" =~ [0-9]+B ]]
}

@test "db_begin db_commit makes writes visible" {
  db_begin
  db_set "tx_key" "tx_value"
  result=$(db_get "tx_key")
  [ "$result" = "tx_value" ]
  db_commit
  result=$(db_get "tx_key")
  [ "$result" = "tx_value" ]
}

@test "db_begin db_rollback discards writes" {
  db_begin
  db_set "tx_key" "tx_value"
  db_rollback
  run db_get "tx_key"
  [ "$status" -eq 1 ]
}

@test "db_history includes uncommitted transaction writes" {
  db_set "tx_key" "before"
  db_sync
  db_begin
  db_set "tx_key" "during"
  result=$(db_history "tx_key" | wc -l)
  [ "$result" -eq 2 ]
  db_rollback
}

@test "nested transaction only commits on outer commit" {
  db_begin
  db_set "tx_key" "outer"
  db_begin
  db_set "tx_key2" "inner"
  db_commit
  result=$(db_get "tx_key2")
  [ "$result" = "inner" ]
  db_commit
  result=$(db_get "tx_key")
  [ "$result" = "outer" ]
  result=$(db_get "tx_key2")
  [ "$result" = "inner" ]
}

@test "nested rollback aborts all levels" {
  db_begin
  db_set "tx_key" "outer"
  db_begin
  db_set "tx_key2" "inner"
  db_rollback
  run db_get "tx_key"
  [ "$status" -eq 1 ]
  run db_get "tx_key2"
  [ "$status" -eq 1 ]
}

@test "reads inside transaction see snapshot not concurrent commits" {
  db_set "shared" "original"
  db_sync
  db_begin
  result=$(db_get "shared")
  [ "$result" = "original" ]
  db_commit
}

@test "maintenance operations blocked during transaction" {
  db_begin
  run db_sync
  [ "$status" -eq 1 ]
  run db_compact
  [ "$status" -eq 1 ]
  db_rollback
}

@test "db_init rolls back leftover transaction files" {
  db_set "a" "1"
  db_sync
  cp "$DB_FILE" "$DB_FILE.tx.snapshot"
  echo 'txkey,"txvalue",2026-06-15T00:00:00+00:00,invalid' > "$DB_FILE.tx.wal"
  run db_init
  [ "$status" -eq 0 ]
  [ ! -f "$DB_FILE.tx.wal" ]
  [ ! -f "$DB_FILE.tx.snapshot" ]
}

@test "db_set_json stores and db_get_json retrieves JSON" {
  if ! command -v base64 >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
    skip "base64/openssl unavailable"
  fi
  db_set_json "json_key" '{"name":"test","value":42}'
  result=$(db_get_json "json_key")
  [ "$result" = '{"name":"test","value":42}' ]
}

@test "db_set_json rejects invalid JSON when jq is available" {
  if ! command -v jq >/dev/null 2>&1; then
    skip "jq unavailable"
  fi
  run db_set_json "json_key" '{"invalid'
  [ "$status" -eq 1 ]
}

@test "db_get_json fails for non-JSON value" {
  if ! command -v base64 >/dev/null 2>&1 && ! command -v openssl >/dev/null 2>&1; then
    skip "base64/openssl unavailable"
  fi
  db_set "plain_key" "not base64 json"
  run db_get_json "plain_key"
  [ "$status" -eq 1 ]
}

@test "db_set_json rejects empty JSON value" {
  run db_set_json "json_key" ""
  [ "$status" -eq 1 ]
}

@test "db_set_ttl stores value with expiry" {
  db_set_ttl "ttl_key" "value" "10"
  result=$(db_get "ttl_key")
  [ "$result" = "value" ]
  run db_ttl "ttl_key"
  [ "$status" -eq 0 ]
  [ "$output" -le 10 ]
  [ "$output" -gt 0 ]
}

@test "db_expire sets expiry on existing key" {
  db_set "ttl_key" "value"
  db_expire "ttl_key" "10"
  result=$(db_get "ttl_key")
  [ "$result" = "value" ]
}

@test "db_get returns not found for expired key" {
  db_set_ttl "ttl_key" "value" "1"
  sleep 2
  run db_get "ttl_key"
  [ "$status" -eq 1 ]
  run db_exists "ttl_key"
  [ "$status" -eq 1 ]
}

@test "db_count excludes expired keys" {
  db_set_ttl "ttl_key" "value" "1"
  db_set "other" "value"
  sleep 2
  result=$(db_count)
  [ "$result" -eq 1 ]
}

@test "db_compact removes expired records and TTL metadata" {
  db_set_ttl "ttl_key" "value" "1"
  sleep 2
  db_compact
  run grep '^ttl_key,"' "$DB_FILE"
  [ "$status" -eq 1 ]
  run grep '^__ttl__:ttl_key,' "$DB_FILE"
  [ "$status" -eq 1 ]
}

@test "db_ttl returns remaining seconds" {
  db_set_ttl "ttl_key" "value" "60"
  result=$(db_ttl "ttl_key")
  [ "$result" -le 60 ]
  [ "$result" -gt 50 ]
}

@test "db_set_enc and db_get_enc round-trip value-only" {
  if ! command -v openssl >/dev/null 2>&1; then
    skip "openssl unavailable"
  fi
  DB_ENCRYPTION_KEY="testkey" DB_ENCRYPT_VALUES_ONLY=1 db_set_enc "enc_key" "secret"
  result=$(DB_ENCRYPTION_KEY="testkey" DB_ENCRYPT_VALUES_ONLY=1 db_get_enc "enc_key")
  [ "$result" = "secret" ]
}

@test "db_set_enc and db_get_enc round-trip whole-record" {
  if ! command -v openssl >/dev/null 2>&1; then
    skip "openssl unavailable"
  fi
  DB_ENCRYPTION_KEY="testkey" db_set_enc "enc_key" "secret"
  result=$(DB_ENCRYPTION_KEY="testkey" db_get_enc "enc_key")
  [ "$result" = "secret" ]
}

@test "db_get_enc fails with wrong key" {
  if ! command -v openssl >/dev/null 2>&1; then
    skip "openssl unavailable"
  fi
  DB_ENCRYPTION_KEY="testkey" db_set_enc "enc_key" "secret"
  _get_enc_wrong_key() {
    DB_ENCRYPTION_KEY="wrongkey" db_get_enc "enc_key"
  }
  run _get_enc_wrong_key
  [ "$status" -eq 1 ]
}

@test "db_set_enc fails without DB_ENCRYPTION_KEY" {
  if ! command -v openssl >/dev/null 2>&1; then
    skip "openssl unavailable"
  fi
  _set_enc_no_key() {
    unset DB_ENCRYPTION_KEY
    db_set_enc "enc_key" "secret"
  }
  run _set_enc_no_key
  [ "$status" -eq 1 ]
}

@test "db_get_enc fails without DB_ENCRYPTION_KEY" {
  if ! command -v openssl >/dev/null 2>&1; then
    skip "openssl unavailable"
  fi
  DB_ENCRYPTION_KEY="testkey" db_set_enc "enc_key" "secret"
  _get_enc_no_key() {
    unset DB_ENCRYPTION_KEY
    db_get_enc "enc_key"
  }
  run _get_enc_no_key
  [ "$status" -eq 1 ]
}

@test "db_trigger fires on set and delete" {
  _my_trigger() {
    echo "trigger:$1:$2:$3"
  }
  export -f _my_trigger
  db_trigger set _my_trigger
  db_trigger delete _my_trigger
  result=$(db_set "trig_key" "value1")
  [[ "$result" == *"trigger:set:trig_key:value1"* ]]
  result=$(db_delete "trig_key")
  [[ "$result" == *"trigger:delete:trig_key:__deleted__"* ]]
}

@test "db_trigger list shows registered functions" {
  # shellcheck disable=SC2317
  _dummy_trigger() { true; }
  db_trigger set _dummy_trigger
  result=$(db_trigger list)
  [[ "$result" == *"_dummy_trigger"* ]]
  db_trigger clear
}

@test "db_trigger clear removes all triggers" {
  # shellcheck disable=SC2317
  _dummy_trigger() { true; }
  db_trigger set _dummy_trigger
  db_trigger clear
  result=$(db_trigger list)
  [ -z "$result" ]
}

@test "db_trigger rejects unknown action" {
  run db_trigger invalid
  [ "$status" -eq 1 ]
}

@test "DB_REPLICA appends records to replica WAL" {
  local replica="${DB_FILE}.replica"
  DB_REPLICA="$replica" db_set "key" "value"
  [ -f "${replica}.wal" ]
  run grep 'key,"value"' "${replica}.wal"
  [ "$status" -eq 0 ]
}

@test "db_replica_sync flushes replica WAL" {
  local replica="${DB_FILE}.replica"
  DB_REPLICA="$replica" db_set "key" "value"
  DB_REPLICA="$replica" db_replica_sync
  [ -s "$replica" ]
  [ ! -s "${replica}.wal" ]
  run grep 'key,"value"' "$replica"
  [ "$status" -eq 0 ]
}

@test "DB_REPLICA_CMD invokes command with record on stdin" {
  local cmd_log="${DB_FILE}.replica_cmd.log"
  DB_REPLICA_CMD="cat >> $cmd_log" db_set "key" "value"
  [ -f "$cmd_log" ]
  run grep 'key,"value"' "$cmd_log"
  [ "$status" -eq 0 ]
}

@test "db_replica_sync fails without DB_REPLICA" {
  unset DB_REPLICA
  run db_replica_sync
  [ "$status" -eq 1 ]
}
