#!/bin/bash
# shellcheck disable=SC2016

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=src/db.sh
source "$SCRIPT_DIR/../src/db.sh"

BENCHMARK_DB="${BENCHMARK_DB:-benchmarks/db.bench}"
BENCHMARK_COUNT="${BENCHMARK_COUNT:-1000}"
BENCHMARK_OUTPUT="${BENCHMARK_OUTPUT:-human}"
BENCHMARK_WORKERS="${BENCHMARK_WORKERS:-5}"
DB_BATCH_SIZE="${DB_BATCH_SIZE:-100}"

db="$BENCHMARK_DB"

_db_now_ms() {
  date +%s%N | awk '{print int($1 / 1000000)}'
}

_db_percentile() {
  local p="$1"
  shift
  if [ $# -eq 0 ]; then
    echo "0"
    return 0
  fi
  printf '%s\n' "$@" | sort -n | awk -v p="$p" -v n="$#" '{
    a[NR] = $1
  }
  END {
    idx = int((p / 100) * (n - 1)) + 1
    if (idx < 1) idx = 1
    if (idx > n) idx = n
    print a[idx]
  }'
}

_bench_stats() {
  local name="$1" elapsed_ms="$2" count="$3" mem_peak_kb="$4"
  shift 4
  local latencies=("$@")

  local ops_per_sec
  if [ "$elapsed_ms" -gt 0 ]; then
    ops_per_sec=$(awk -v c="$count" -v e="$elapsed_ms" 'BEGIN {printf "%.2f", c / (e / 1000)}')
  else
    ops_per_sec="N/A"
  fi

  local min_lat max_lat p50 p95 p99
  if [ ${#latencies[@]} -gt 0 ]; then
    min_lat=$(printf '%s\n' "${latencies[@]}" | sort -n | head -n 1)
    max_lat=$(printf '%s\n' "${latencies[@]}" | sort -n | tail -n 1)
    p50=$(_db_percentile 50 "${latencies[@]}")
    p95=$(_db_percentile 95 "${latencies[@]}")
    p99=$(_db_percentile 99 "${latencies[@]}")
  else
    min_lat="0"
    max_lat="0"
    p50="0"
    p95="0"
    p99="0"
  fi

  if [ "$BENCHMARK_OUTPUT" = "json" ]; then
    printf '{"name":"%s","count":%s,"elapsed_ms":%s,"ops_per_sec":%s,"latency_ms":{"min":%s,"p50":%s,"p95":%s,"p99":%s,"max":%s},"memory_peak_kb":%s}' \
      "$name" "$count" "$elapsed_ms" "$ops_per_sec" "$min_lat" "$p50" "$p95" "$p99" "$max_lat" "$mem_peak_kb"
  else
    printf '%-30s count=%-6s ops/sec=%-10s elapsed=%-6s ms  latency(min/p50/p95/p99/max)=%s/%s/%s/%s/%s ms  mem_peak=%s KB\n' \
      "$name" "$count" "$ops_per_sec" "$elapsed_ms" "$min_lat" "$p50" "$p95" "$p99" "$max_lat" "$mem_peak_kb"
  fi
}

_bench_run() {
  local name="$1" count="$2" cmd="$3" setup_cmd="${4:-}"
  local latencies=()
  local start end elapsed op_start op_end op_latency
  local mem_before mem_after mem_peak current_mem

  db_init >/dev/null 2>&1
  : > "$db"
  : > "$db.wal"

  if [ -n "$setup_cmd" ]; then
    eval "$setup_cmd"
  fi

  mem_before=$(_db_memory_usage_kb)
  mem_peak=$mem_before
  start=$(_db_now_ms)

  for ((i = 0; i < count; i++)); do
    op_start=$(_db_now_ms)
    eval "$cmd"
    op_end=$(_db_now_ms)
    op_latency=$((op_end - op_start))
    latencies+=("$op_latency")

    if [ $((i % 100)) -eq 0 ]; then
      current_mem=$(_db_memory_usage_kb)
      if [ "$current_mem" -gt "$mem_peak" ]; then
        mem_peak=$current_mem
      fi
    fi
  done

  end=$(_db_now_ms)
  elapsed=$((end - start))

  mem_after=$(_db_memory_usage_kb)
  if [ "$mem_after" -gt "$mem_peak" ]; then
    mem_peak=$mem_after
  fi

  _bench_stats "$name" "$elapsed" "$count" "$mem_peak" "${latencies[@]}"
}

_bench_run_concurrent() {
  local name="$1" count="$2" workers="$3" cmd="$4" setup_cmd="${5:-}"
  local per_worker=$((count / workers))
  local start end elapsed
  local pids=()
  local mem_before mem_after mem_peak current_mem

  db_init >/dev/null 2>&1
  : > "$db"
  : > "$db.wal"

  if [ -n "$setup_cmd" ]; then
    eval "$setup_cmd"
  fi

  mem_before=$(_db_memory_usage_kb)
  mem_peak=$mem_before
  start=$(_db_now_ms)

  for ((w = 0; w < workers; w++)); do
    (
      for ((i = 0; i < per_worker; i++)); do
        eval "$cmd"
      done
    ) &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  end=$(_db_now_ms)
  elapsed=$((end - start))

  mem_after=$(_db_memory_usage_kb)
  if [ "$mem_after" -gt "$mem_peak" ]; then
    mem_peak=$mem_after
  fi

  _bench_stats "$name" "$elapsed" "$count" "$mem_peak"
}

_bench_insert() {
  db_set "key_$1" "value_$1"
}

_bench_read() {
  db_get "key_$1" >/dev/null
}

_bench_delete() {
  db_delete "key_$1"
}

_bench_mset() {
  local start="$1"
  local batch=()
  for ((j = 0; j < DB_BATCH_SIZE; j++)); do
    local idx=$((start + j))
    batch+=("key_$idx" "value_$idx")
  done
  db_mset "${batch[@]}"
}

main() {
  mkdir -p "$(dirname "$BENCHMARK_DB")"

  if [ "$BENCHMARK_OUTPUT" = "json" ]; then
    echo '['
  else
    echo "Benchmarks: count=$BENCHMARK_COUNT, workers=$BENCHMARK_WORKERS, batch_size=$DB_BATCH_SIZE, db=$BENCHMARK_DB"
    echo
  fi

  _bench_run "insert" "$BENCHMARK_COUNT" '_bench_insert $i'
  if [ "$BENCHMARK_OUTPUT" = "json" ]; then echo ','; fi

  _bench_run "read" "$BENCHMARK_COUNT" '_bench_read $((i % BENCHMARK_COUNT))' 'for ((k=0; k<BENCHMARK_COUNT; k++)); do _bench_insert $k; done'
  if [ "$BENCHMARK_OUTPUT" = "json" ]; then echo ','; fi

  _bench_run "delete" "$BENCHMARK_COUNT" '_bench_delete $i' 'for ((k=0; k<BENCHMARK_COUNT; k++)); do _bench_insert $k; done'
  if [ "$BENCHMARK_OUTPUT" = "json" ]; then echo ','; fi

  _bench_run "mset_batch" "$((BENCHMARK_COUNT / DB_BATCH_SIZE))" '_bench_mset $((i * DB_BATCH_SIZE))'
  if [ "$BENCHMARK_OUTPUT" = "json" ]; then echo ','; fi

  _bench_run_concurrent "concurrent_insert" "$BENCHMARK_COUNT" "$BENCHMARK_WORKERS" 'db_set "concurrent_key_${RANDOM}_${i}" "value_${RANDOM}"'
  if [ "$BENCHMARK_OUTPUT" = "json" ]; then echo ','; fi

  _bench_run_concurrent "concurrent_read" "$BENCHMARK_COUNT" "$BENCHMARK_WORKERS" 'db_get "key_$((i % BENCHMARK_COUNT))" >/dev/null' 'for ((k=0; k<BENCHMARK_COUNT; k++)); do _bench_insert $k; done'

  if [ "$BENCHMARK_OUTPUT" = "json" ]; then
    echo ']'
  fi

  rm -f "$db" "$db.wal" "$db.lock"
}

main "$@"
