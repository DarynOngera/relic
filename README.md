# ddia

A simple append-only key-value database implemented in Bash.

## Setup

```bash
source db.sh
```

## Usage

```bash
db_init                          # Create database file if missing
db_set "key" "value"             # Store a value (supports commas in values)
db_get "key"                     # Retrieve the latest value
db_delete "key"                  # Mark a key as deleted (tombstone)
db_exists "key"                  # Check if key exists (exit code 0/1)
db_history "key"                 # Show all values with timestamps
db_list                          # List all non-deleted keys
db_stats                         # Show total records, unique keys, file size
```

## Format

Records are stored as quoted CSV with timestamps:

```
key,"value",2026-06-12T02:56:00+00:00
```

## Design

- Append-only log: no in-place updates
- Tombstone deletion: soft deletes via `__deleted__` marker
- Compaction can be added later to remove stale records
