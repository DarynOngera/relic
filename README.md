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
| `make lint` | Run shellcheck on all .sh files |
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
├── src/           # Core database engine
├── tests/         # Test suites
├── benchmarks/    # Performance tests
├── docs/          # Documentation and ADRs
├── Makefile
├── README.md
└── Task.md
```
