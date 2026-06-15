# DDIA Key-Value Database

Production-grade append-only key-value database implemented in pure Bash.

## Dependencies

- Bash 4.0+
- `sha256sum` (mandatory — checksum validation)
- `flock` (mandatory — concurrent access)
- `mktemp` (atomic temp files, usually pre-installed)
- `jq` (optional, for JSON operations)
- `openssl` (optional, for encryption)
- `bats` (development only, for testing)

## Quick Start

```bash
make setup          # Create directories
source src/db.sh
db_init             # Auto-migrates old format if needed
db_set "name" "Daryn"
db_get "name"
db_sync             # Flush WAL to main database
```

## API Reference

### Core Operations

| Function | Description |
|----------|-------------|
| `db_init` | Initialize database (auto-migrates old format) |
| `db_set <key> <value>` | Store a key-value pair |
| `db_get <key>` | Retrieve a value |
| `db_delete <key>` | Mark key as deleted (tombstone) |
| `db_exists <key>` | Check if key exists and is not deleted |
| `db_history <key>` | Show all values for a key |
| `db_list` | List all active keys |
| `db_stats` | Show database statistics |
| `db_mset <key1> <value1> [...]` | Batch set multiple key-value pairs |
| `db_mget <key1> [...]` | Batch get values (output: `key<TAB>value`) |
| `db_incr <key> [amount]` | Atomically increment an integer value |
| `db_decr <key> [amount]` | Atomically decrement an integer value |
| `db_update <key> <expected> <new>` | Update only if current value matches expected |
| `db_keys <pattern>` | List active keys matching a shell glob |
| `db_search <term>` | List active keys whose value contains term |
| `db_clear` | Purge all data and write a `__system__` marker with value `__cleared__` |
| `db_count` | Count active keys |
| `db_size` | Human-readable total database size |
| `db_set_json <key> <json>` | Store a JSON value (Base64-encoded; validated by `jq` if available) |
| `db_get_json <key>` | Retrieve and decode a JSON value |
| `db_set_ttl <key> <value> <ttl_seconds>` | Store a value with expiration |
| `db_expire <key> <ttl_seconds>` | Set expiration on an existing key |
| `db_ttl <key>` | Show remaining TTL seconds |
| `db_set_enc <key> <value>` | Store an encrypted value |
| `db_get_enc <key>` | Retrieve and decrypt a value |
| `db_trigger set\|delete\|list\|clear <func>` | Register/clear sourced Bash trigger callbacks |
### Data Integrity & Maintenance

| Function | Description |
|----------|-------------|
| `db_sync` | Flush WAL to main database |
| `db_verify` | Scan database for corruption |
| `db_migrate` | Manually migrate old format to new |
| `db_compact` | Remove tombstones and overwritten records |
| `db_vacuum` | Compact and verify the database |

### Transactions

| Function | Description |
|----------|-------------|
| `db_begin` | Start (or nest) a transaction |
| `db_commit` | Commit the current transaction level |
| `db_rollback` | Abort the entire transaction |
| `db_backup <dest>` | Hot backup to `<dest>` and `<dest>.wal` |
| `db_restore <src>` | Restore from backup (refuses non-empty db; supports `.gz`) |
| `db_truncate [max_bytes]` | Rotate and gzip db if larger than max (default 10 MB) |
| `db_replica_sync` | Flush replica WAL to main replica file |

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make setup` | Create project directories |
| `make test` | Run unit, integration, crash, fuzz, and property tests (requires bats) |
| `make lint` | Run shellcheck on all .sh, .bats, and helper files |
| `make clean` | Remove build artifacts and test data |
| `make benchmark` | Run performance benchmarks |
| `make stress` | Run manual stress tests (`RUN_STRESS_TESTS=1`) |
| `make install` | Install to /usr/local/bin (optional) |

## Format

Records are stored as quoted CSV with timestamps and SHA256 checksums:

```
key,"value",2026-06-12T02:56:00+00:00,abc123...
```

Keys starting with `__` (double underscore) are reserved for internal system records (e.g. `db_clear` writes a `__system__` record whose value is `__cleared__`) and are hidden from user-facing queries.

## Design

- **Append-only log**: No in-place updates
- **Tombstone deletion**: Soft deletes via `__deleted__` marker
- **Write-Ahead Log (WAL)**: Records are appended to the WAL and fsync'd per write; explicit `db_sync` flushes the WAL into the main database file
- **SHA256 checksums**: Every record validated on read/write
- **Auto-migration**: Old format (3 fields) automatically upgraded to new format (4 fields)
- **File locking**: `flock` for concurrent read/write access
- **Signal handling**: SIGINT/SIGTERM cleanup during writes
- **Compaction**: `db_compact` removes tombstones and overwritten records; `db_vacuum` compacts and verifies
- **Hot backup/restore**: `db_backup`/`db_restore` with validation
- **Log rotation**: `db_truncate` rotates db segments when size exceeds threshold; reads with rotated segments spawn one scan per segment
- **Schema versioning**: `__schema_version__` system key tracked automatically
- **Logging**: `DB_LOG_LEVEL` and `DB_LOG_FILE` for debug/info/warn/error output
- **Benchmarks**: `make benchmark` with human or JSON output, latency percentiles, and memory tracking
- **JSON values**: Base64-encoded storage with optional `jq` validation
- **TTL / expiration**: Hidden `__ttl__:<key>` metadata; expired keys are ignored and removed on compaction
- **Encryption at rest**: AES-256-CBC via `openssl`; whole-record by default, value-only mode optional
- **Triggers**: Sourced Bash callbacks fired on `set` and `delete` events
- **Schema migrations**: Ordered `migrations/v*_to_v*.sh` scripts applied manually via `db_migrate`
- **Compression**: gzip for rotated log segments and optional backup compression
- **Replication**: Local replica file plus optional `DB_REPLICA_CMD` hook, with fsync'd writes

## Benchmarks

```bash
make benchmark                            # human-readable output
BENCHMARK_OUTPUT=json make benchmark      # JSON output
BENCHMARK_COUNT=10000 make benchmark      # larger workload
BENCHMARK_WORKERS=10 make benchmark       # more concurrency
```

Reported metrics include throughput (ops/sec), min/p50/p95/p99/max latency in milliseconds, and peak memory usage.

## Profiling

Use `/usr/bin/time` for a high-level profile:

```bash
/usr/bin/time -v bash benchmarks/run.sh
```

Use `strace` to analyze syscalls (significantly slower):

```bash
strace -c -e trace=file,desc bash benchmarks/run.sh
```

## Testing

```bash
make test                              # fast unit/integration/fuzz/property/crash tests
make stress                            # manual stress tests (default 500 records)
RUN_STRESS_TESTS=1 STRESS_COUNT=10000 make stress   # larger stress run
bats tests/integration.bats            # run one suite
```

Test suites:

- `tests/core.bats` — unit tests for all API functions
- `tests/integration.bats` — concurrent readers/writers, atomic counters, conditional updates
- `tests/crash.bats` — `kill -9` mid-write recovery with fsync and `DB_NO_FSYNC=1`
- `tests/fuzz.bats` — random keys/values including commas
- `tests/property.bats` — property-based invariants (latest write wins, count correctness, etc.)
- `tests/stress.bats` — manual larger-scale insert/read/delete/compact tests

## Environment Variables

| Variable | Description |
|----------|-------------|
| `db` | Database base path (default: `db`) |
| `DB_LOG_LEVEL` | Logging level: `debug`, `info`, `warn`, `error` (default: `warn`) |
| `DB_LOG_FILE` | Optional log file path |
| `DB_LOCK_TIMEOUT` | Lock acquisition timeout in seconds (default: `10`) |
| `DB_BATCH_SIZE` | Chunk size for `db_mset` writes (default: `100`) |
| `DB_NO_FSYNC` | Set to `1` to disable per-write WAL fsync (default: `0`) |
| `DB_ENCRYPTION_KEY` | Passphrase for `db_set_enc` / `db_get_enc` |
| `DB_ENCRYPT_VALUES_ONLY` | Set to `1` to encrypt only values; default whole-record encryption |
| `DB_REPLICA` | Local replica base path; records are appended to `<path>.wal` |
| `DB_REPLICA_CMD` | Command invoked with each record on stdin for remote replication |
| `DB_BACKUP_COMPRESS` | Set to `1` to gzip backups (default: `0`) |
| `BENCHMARK_COUNT` | Number of operations per benchmark (default: `1000`) |
| `BENCHMARK_OUTPUT` | `human` or `json` (default: `human`) |
| `BENCHMARK_WORKERS` | Parallel workers for concurrent benchmarks (default: `5`) |
| `RUN_STRESS_TESTS` | Set to `1` to enable stress tests (default: `0`) |
| `STRESS_COUNT` | Number of records for stress insert/delete/compact (default: `500`) |
| `STRESS_READ_KEYS` | Number of keys to read in stress read test (default: `50`) |

## Project Structure

```
├── src/
│   ├── db.sh           # Public entry point (sources all modules)
│   ├── db_utils.sh     # Checksums, validation, logging, memory helpers
│   ├── db_lock.sh      # flock read/write helpers
│   ├── db_storage.sh   # WAL append/sync and read helpers
│   ├── db_ops.sh       # Core operations (set, get, delete, etc.)
│   ├── db_tx.sh        # Transactions (begin/commit/rollback)
│   ├── db_maint.sh     # Maintenance (init, sync, verify, stats, migrate)
│   ├── db_json.sh      # JSON value support
│   ├── db_ttl.sh       # TTL / expiration
│   ├── db_crypto.sh    # Encryption at rest
│   ├── db_triggers.sh  # Write/delete triggers
│   └── db_replica.sh   # Replication helpers
├── migrations/         # Schema migration scripts
│   ├── v0_to_v1.sh
│   └── v1_to_v2.sh
├── tests/              # Test suites
│   ├── core.bats
│   ├── integration.bats
│   ├── crash.bats
│   ├── fuzz.bats
│   ├── property.bats
│   ├── stress.bats
│   └── helpers/        # Test helper scripts
├── .github/workflows/  # CI/CD
│   └── ci.yml
├── benchmarks/         # Performance tests
├── docs/               # Documentation and ADRs
├── Makefile
├── README.md
└── Task.md
```
