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
| `db_clear` | Purge all data and write `__cleared__` marker |
| `db_count` | Count active keys |
| `db_size` | Human-readable total database size |

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
| `db_restore <src>` | Restore from backup (refuses non-empty db) |
| `db_truncate [max_bytes]` | Rotate db if larger than max (default 10 MB) |

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make setup` | Create project directories |
| `make test` | Run all tests (requires bats) |
| `make lint` | Run shellcheck on all .sh and .bats files |
| `make clean` | Remove build artifacts and test data |
| `make benchmark` | Run performance benchmarks |
| `make install` | Install to /usr/local/bin (optional) |

## Format

Records are stored as quoted CSV with timestamps and SHA256 checksums:

```
key,"value",2026-06-12T02:56:00+00:00,abc123...
```

Keys starting with `__` (double underscore) are reserved for internal system records (e.g. the `__cleared__` marker written by `db_clear`) and are hidden from user-facing queries.

## Design

- **Append-only log**: No in-place updates
- **Tombstone deletion**: Soft deletes via `__deleted__` marker
- **Write-Ahead Log (WAL)**: Immediate durability, flushed via `db_sync`
- **SHA256 checksums**: Every record validated on read/write
- **Auto-migration**: Old format (3 fields) automatically upgraded to new format (4 fields)
- **File locking**: `flock` for concurrent read/write access
- **Signal handling**: SIGINT/SIGTERM cleanup during writes
- **Compaction**: `db_compact` removes tombstones and overwritten records; `db_vacuum` compacts and verifies
- **Hot backup/restore**: `db_backup`/`db_restore` with validation
- **Log rotation**: `db_truncate` rotates db segments when size exceeds threshold
- **Schema versioning**: `__schema_version__` system key tracked automatically
- **Logging**: `DB_LOG_LEVEL` and `DB_LOG_FILE` for debug/info/warn/error output
- **Benchmarks**: `make benchmark` with human or JSON output, latency percentiles, and memory tracking

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

## Environment Variables

| Variable | Description |
|----------|-------------|
| `db` | Database base path (default: `db`) |
| `DB_LOG_LEVEL` | Logging level: `debug`, `info`, `warn`, `error` (default: `warn`) |
| `DB_LOG_FILE` | Optional log file path |
| `DB_LOCK_TIMEOUT` | Lock acquisition timeout in seconds (default: `10`) |
| `DB_BATCH_SIZE` | Chunk size for `db_mset` writes (default: `100`) |
| `BENCHMARK_COUNT` | Number of operations per benchmark (default: `1000`) |
| `BENCHMARK_OUTPUT` | `human` or `json` (default: `human`) |
| `BENCHMARK_WORKERS` | Parallel workers for concurrent benchmarks (default: `5`) |

## Project Structure

```
├── src/
│   ├── db.sh           # Public entry point (sources all modules)
│   ├── db_utils.sh     # Checksums, validation, logging, memory helpers
│   ├── db_lock.sh      # flock read/write helpers
│   ├── db_storage.sh   # WAL append/sync and read helpers
│   ├── db_ops.sh       # Core operations (set, get, delete, etc.)
│   ├── db_tx.sh        # Transactions (begin/commit/rollback)
│   └── db_maint.sh     # Maintenance (init, sync, verify, stats, migrate)
├── tests/              # Test suites
├── benchmarks/         # Performance tests
├── docs/               # Documentation and ADRs
├── Makefile
├── README.md
└── Task.md
```
