#!/bin/bash

# shellcheck shell=bash
# Production-grade append-only key-value database in pure Bash
# Record format: key,"value",timestamp,sha256sum
# WAL file: db.wal (same format, flushed to db via db_sync)

_db_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Default database file; can be overridden before sourcing or before db_init
db=${db:-}

# shellcheck source=src/db_utils.sh
source "$_db_script_dir/db_utils.sh"

# shellcheck source=src/db_lock.sh
source "$_db_script_dir/db_lock.sh"

# shellcheck source=src/db_storage.sh
source "$_db_script_dir/db_storage.sh"

# shellcheck source=src/db_ops.sh
source "$_db_script_dir/db_ops.sh"

# shellcheck source=src/db_tx.sh
source "$_db_script_dir/db_tx.sh"

# shellcheck source=src/db_maint.sh
source "$_db_script_dir/db_maint.sh"

# shellcheck source=src/db_json.sh
source "$_db_script_dir/db_json.sh"

# shellcheck source=src/db_ttl.sh
source "$_db_script_dir/db_ttl.sh"

# shellcheck source=src/db_crypto.sh
source "$_db_script_dir/db_crypto.sh"

# shellcheck source=src/db_triggers.sh
source "$_db_script_dir/db_triggers.sh"

# shellcheck source=src/db_replica.sh
source "$_db_script_dir/db_replica.sh"
