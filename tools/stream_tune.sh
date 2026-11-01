#!/bin/bash
# For a model larger than memory: try several sizes of the GPU expert cache and measure each (all experts stay mapped
# from the file, the GPU keeps the ones used most). Results: build/tune-<model-id>.txt
# Usage: stream_tune.sh <model-id> <cache-MiB…>     e.g. stream_tune.sh deepseek-v4.1-flash-q4 88064 96256 101376
# Watch `sysctl vm.swapusage` while it runs: a cache that is too large makes macOS swap.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="${1:?usage: stream_tune.sh <model-id> <cache-MiB…>}"; shift
LAYERS=$(/usr/bin/python3 -I "$ROOT/tools/gguf_peek.py" "$HOME/Library/Application Support/MacAIMagic/models/$ID/$ID-00001-of-"*.gguf 2>/dev/null | sed -n 's/.*\.block_count = //p' | head -1)
export LLAMA_MMAP_PREFETCH=0              # no read-ahead of the whole file at load
export LLAMA_MOE_CACHE_MAX_BATCH=8        # up to 8 tokens read their experts from the cache, larger batches copy them
export GGML_OP_OFFLOAD_MIN_BATCH=9
OUT="$ROOT/build/tune-$ID.txt"
mkdir -p "$ROOT/build"

for MIB in "$@"; do
  "$ROOT/scripts/stop_engine.sh"
  echo "=== $ID, expert cache $MIB MiB, $(date +%H:%M)" | tee -a "$OUT"
  EXTRA_ARGS="--no-repack --moe-cache-mib $MIB -lv 4 $EXTRA_ARGS" "$ROOT/scripts/run_engine.sh" "$ID" "${LAYERS:-99}" 32768 &
  /usr/bin/python3 -I "$ROOT/tools/stream_bench.py" "cache $MIB MiB" 3 200 | tail -1 | tee -a "$OUT"
  echo "swap: $(sysctl -n vm.swapusage)" | tee -a "$OUT"
  "$ROOT/scripts/stop_engine.sh"
  grep -a "llama_moe_cache:" "$ROOT/engine-test.log" | sed 's/^[0-9.]* I //' | tee -a "$OUT"
done
