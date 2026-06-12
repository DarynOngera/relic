# DDIA Key-Value Database

Production-grade append-only key-value database implemented in pure Bash.

## Dependencies

- Bash 4.0+
- `flock` (Linux file locking)
- `sha256sum` (checksums, usually pre-installed)
- `mktemp` (atomic temp files, usually pre-installed)
- `jq` (optional, for JSON operations)
- `openssl` (optional, for encryption)
- `bats` (development only, for testing)

## Quick Start

```bash
make setup          # Create directories
source src/db.sh
db_init
db_set "name" "Daryn"
db_get "name"
```

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

Records are stored as quoted CSV with timestamps:

```
key,"value",2026-06-12T02:56:00+00:00
```

## Design

- **Append-only log**: No in-place updates
- **Tombstone deletion**: Soft deletes via `__deleted__` marker
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
