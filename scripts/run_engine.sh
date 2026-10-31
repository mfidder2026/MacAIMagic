#!/bin/bash
# Start the engine from the command line with the same arguments the app uses (log: engine-test.log).
# Usage: run_engine.sh [n-cpu-moe] [ctx-size]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$HOME/Library/Application Support/MacDeepSeek/models/Maya-XS"
cd "$ROOT"
LLAMA_ARG_LAZY_MODE=auto exec ./engine/bin/llama-server \
  --model "$M/DeepSeek-V4.1-Flash-1017-Maya-XS-IQ1_S-00001-of-00005.gguf" \
  --mmproj "$M/mmproj-F16.gguf" \
  --host 127.0.0.1 --port 8080 --ctx-size "${2:-65536}" \
  --n-gpu-layers 999 --n-cpu-moe "${1:-2}" --flash-attn on --fit off \
  --threads 12 --parallel 1 --jinja --reasoning-format deepseek --metrics \
  --ubatch-size 1024 --batch-size 2048 --alias deepseek-v4.1-flash $EXTRA_ARGS > engine-test.log 2>&1
