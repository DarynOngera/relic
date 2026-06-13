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

## Design

- **Append-only log**: No in-place updates
- **Tombstone deletion**: Soft deletes via `__deleted__` marker
- **Write-Ahead Log (WAL)**: Immediate durability, flushed via `db_sync`
- **SHA256 checksums**: Every record validated on read/write
- **Auto-migration**: Old format (3 fields) automatically upgraded to new format (4 fields)
- **File locking**: `flock` for concurrent read/write access
- **Signal handling**: SIGINT/SIGTERM cleanup during writes
- **Compaction**: Can be added later to remove stale records

## Project Structure

```
├── src/
│   ├── db.sh           # Public entry point (sources all modules)
│   ├── db_utils.sh     # Checksums, validation, record helpers
│   ├── db_lock.sh      # flock read/write helpers
│   ├── db_storage.sh   # WAL append/sync and read helpers
│   ├── db_ops.sh       # Core operations (set, get, delete, etc.)
│   └── db_maint.sh     # Maintenance (init, sync, verify, stats, migrate)
├── tests/              # Test suites
├── benchmarks/         # Performance tests
├── docs/               # Documentation and ADRs
├── Makefile
├── README.md
└── Task.md
```
