# Task: Production-Grade KV Database

A learning project to build a comprehensive, production-grade append-only key-value database in pure Bash.

## Dependency Policy

- **Core engine**: Pure Bash
- **External tools**: Only when they provide essential capabilities that are infeasible in pure Bash (file locking, crypto, JSON parsing)
- **Graceful degradation**: All features check for their dependencies and provide clear error messages if missing
- **Dev dependencies**: bats (testing), shellcheck (linting)

## Phase 0 — Project Foundation (In Progress)

- [x] Create project structure (src/, tests/, benchmarks/, docs/)
- [x] Create Makefile with standard targets
- [x] Create README.md and Task.md
- [x] Create AGENTS.md for project context
- [ ] Set up .gitignore for build artifacts
- [ ] Add Makefile targets: setup, test, lint, clean, benchmark

## Phase 1 — Data Integrity & Safety

- [ ] Atomic writes (write to temp file, mv atomically)
- [ ] File locking with `flock` for concurrent access
- [ ] `fsync` after writes for durability
- [ ] Checksum validation (SHA256 per record)
- [ ] Write-ahead log (WAL) format for crash recovery
- [ ] Validate record format on read (detect corruption)
- [ ] Handle SIGINT/SIGTERM gracefully during writes

## Phase 2 — Core Operations (Production API)

- [ ] `db_mset` / `db_mget` — batch operations
- [ ] `db_incr` / `db_decr` — atomic counter operations
- [ ] `db_update` — conditional update (only if value matches)
- [ ] `db_clear` — purge all data
- [ ] `db_count` — active key count
- [ ] `db_keys` — with prefix and pattern matching
- [ ] `db_search` — full-text value search
- [ ] `db_size` — human-readable file size

## Phase 3 — Compaction & Maintenance

- [ ] `db_compact` — remove tombstones and overwrites
- [ ] `db_vacuum` — compact + rebuild indexes
- [ ] `db_backup` — hot backup (copy while holding read lock)
- [ ] `db_restore` — restore from backup with validation
- [ ] `db_truncate` — size-limited log rotation
- [ ] `db_migrate` — schema version migration

## Phase 4 — Transactions (Basic ACID)

- [ ] `db_begin` — start transaction
- [ ] `db_commit` — commit changes
- [ ] `db_rollback` — abort transaction
- [ ] Snapshot isolation for reads
- [ ] Deadlock detection / timeout
- [ ] Transaction log for recovery

## Phase 5 — Performance & Observability

- [ ] Benchmark suite (inserts, reads, deletes, concurrent)
- [ ] Logging framework (debug/info/warn/error levels)
- [ ] Metrics: ops/sec, latency percentiles, lock wait times
- [ ] Memory usage tracking
- [ ] Performance profiling with `time` and `strace`
- [ ] Configurable batch size and flush interval

## Phase 6 — Testing (Production-Grade)

- [ ] Unit tests with `bats` (Bash Automated Testing System)
- [ ] Integration tests for concurrency (parallel readers/writers)
- [ ] Crash recovery tests (kill -9 mid-write)
- [ ] Fuzz testing with random keys/values
- [ ] Property-based testing (e.g., `db_get` always returns latest `db_set`)
- [ ] Stress tests (millions of records)
- [ ] CI/CD pipeline (GitHub Actions)

## Phase 7 — Advanced Features

- [ ] JSON value support (with `jq` validation)
- [ ] TTL / automatic expiration
- [ ] Schema versioning and migrations
- [ ] Encryption at rest (openssl integration)
- [ ] Compression (gzip for old log segments)
- [ ] Replication (append to remote replica)
- [ ] Triggers (callbacks on write/delete)

## Phase 8 — Documentation & Tooling

- [ ] Architecture decision records (ADRs)
- [ ] API reference documentation
- [ ] Performance tuning guide
- [ ] Docker container for testing
- [ ] CLI tool (`db-cli`) with subcommands
- [ ] Shell completions (bash/zsh)
- [ ] Man page

## Current Status

- **Phase 0**: In progress
- **Completed**: Basic append-only log, tombstone deletion, timestamps, input validation, db_history, db_exists, db_list, db_stats
- **Known Issues**: Needs atomic writes, file locking, and comprehensive tests

## Design Decisions

- **Format**: Quoted CSV (`key,"value",timestamp`) to support commas in values
- **Storage**: Append-only log with tombstone deletion
- **Concurrency**: File locking with `flock` (read-write locks)
- **Transactions**: Copy-on-write snapshots via temp files
- **Performance target**: 100+ ops/sec for simple workloads
