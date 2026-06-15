# Task: Production-Grade KV Database

A learning project to build a comprehensive, production-grade append-only key-value database in pure Bash.

## Dependency Policy

- **Core engine**: Pure Bash
- **External tools**: Only when they provide essential capabilities that are infeasible in pure Bash (file locking, crypto, JSON parsing)
- **Graceful degradation**: All features check for their dependencies and provide clear error messages if missing
- **Dev dependencies**: bats (testing), shellcheck (linting)

## Phase 0 — Project Foundation (Complete)

- [x] Create project structure (src/, tests/, benchmarks/, docs/)
- [x] Create Makefile with standard targets
- [x] Create README.md and Task.md
- [x] Create AGENTS.md for project context
- [x] Set up .gitignore for build artifacts
- [x] Add Makefile targets: setup, test, lint, clean, benchmark

## Phase 1 — Data Integrity & Safety (Complete)

- [x] Atomic writes (write to temp file, mv atomically)
- [x] File locking with `flock` for concurrent access
- [x] `fsync` after WAL writes for durability
- [x] Checksum validation (SHA256 per record)
- [x] Write-ahead log (WAL) format for crash recovery
- [x] Validate record format on read (detect corruption)
- [x] Handle SIGINT/SIGTERM gracefully during migration

## Phase 2 — Core Operations (Production API) (Complete)

- [x] `db_mset` / `db_mget` — batch operations
- [x] `db_incr` / `db_decr` — atomic counter operations
- [x] `db_update` — conditional update (only if value matches)
- [x] `db_clear` — purge all data
- [x] `db_count` — active key count
- [x] `db_keys` — with prefix and pattern matching
- [x] `db_search` — full-text value search
- [x] `db_size` — human-readable file size

## Phase 3 — Compaction & Maintenance (Complete)

- [x] `db_compact` — remove tombstones and overwrites
- [x] `db_vacuum` — compact + rebuild indexes
- [x] `db_backup` — hot backup (copy while holding read lock)
- [x] `db_restore` — restore from backup with validation
- [x] `db_truncate` — size-limited log rotation
- [x] `db_migrate` — schema version migration

## Phase 4 — Transactions (Basic ACID) (Complete)

- [x] `db_begin` — start transaction
- [x] `db_commit` — commit changes
- [x] `db_rollback` — abort transaction
- [x] Snapshot isolation for reads
- [x] Deadlock detection / timeout
- [x] Transaction log for recovery

## Phase 5 — Performance & Observability (Complete)

- [x] Benchmark suite (inserts, reads, deletes, concurrent)
- [x] Logging framework (debug/info/warn/error levels)
- [x] Metrics: ops/sec, latency percentiles, lock wait times
- [x] Memory usage tracking
- [x] Performance profiling with `time` and `strace`
- [x] Configurable batch size and flush interval

## Phase 6 — Testing

- [x] Unit tests with `bats` (Bash Automated Testing System)
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

- **Phase 0**: Complete
- **Phase 1**: Complete
- **Phase 2**: Complete
- **Phase 3**: Complete
- **Phase 4**: Complete
- **Phase 5**: Complete
- **Completed**: Basic append-only log, tombstone deletion, timestamps, input validation, db_history, db_exists, db_list, db_stats, .gitignore, Makefile targets, atomic writes, file locking, fsync, SHA256 checksums, WAL, record validation, signal handling during migration, auto-migration, db_verify, modular engine split into src/db_*.sh modules, Phase 2 operations (batch, counters, conditional, search), Phase 3 maintenance (compact, vacuum, backup, restore, truncate, schema versioning), Phase 4 transactions (begin/commit/rollback, snapshot isolation, nested transactions, lock timeout, recovery), Phase 5 observability (benchmarks, logging, metrics, memory tracking, profiling)
- **Known Issues**: WAL durability is now per-write fsync; large workloads can set `DB_NO_FSYNC=1` to trade durability for speed. No CLI wrapper yet; use `source src/db.sh`.

## Design Decisions

- **Format**: Quoted CSV with checksum (`key,"value",timestamp,sha256sum`) to support commas in values and detect corruption
- **Storage**: Append-only log with tombstone deletion, WAL for immediate durability
- **Concurrency**: File locking with `flock` (read-write locks)
- **Transactions**: Copy-on-write snapshots via temp files
- **Performance target**: 100+ ops/sec for simple workloads
- **Migration**: Auto-migrate old format (3 fields) to new format (4 fields) on db_init
