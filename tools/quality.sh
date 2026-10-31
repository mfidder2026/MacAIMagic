#!/bin/bash
# Quality of a compact model against its Q4 version (the reference), on the same text:
#   how often both pick the same next token ("Same top p"), the KL divergence, and perplexity.
# Usage: quality.sh <family: deepseek|glm> [chunks]
#   1. runs the Q4 model once and saves its token probabilities (base file, a few GB)
#   2. runs the compact model against that base and prints the comparison
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAMILY="${1:?usage: quality.sh <deepseek|glm> [chunks]}"
CHUNKS="${2:-24}"
MODELS="${MODELS_DIR:-$HOME/Library/Application Support/MacDeepSeek/models}"
OUT="$ROOT/build/quality"
mkdir -p "$OUT"

case "$FAMILY" in
  deepseek) REF=deepseek-v4.1-flash-q4; TEST=deepseek-v4.1-flash-compact; REF_CPU=24; TEST_CPU=2 ;;
  glm)      REF=glm-5.3-flash-q4;       TEST=glm-5.3-flash-compact;       REF_CPU=24; TEST_CPU=0 ;;
  *) echo "unknown family $FAMILY"; exit 1 ;;
esac
first() { /usr/bin/python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(next(x for x in m["models"] if x["id"]==sys.argv[2])["files"][0]["local"])' "$ROOT/tools/models.json" "$1"; }

# the evaluation text: llama.cpp's documentation (prose, lists and code), the same for every model
TEXT="$OUT/eval.txt"
[ -s "$TEXT" ] || cat "$ROOT"/third_party/llama.cpp/README.md "$ROOT"/third_party/llama.cpp/docs/*.md > "$TEXT"

run() {  # model-id n-cpu-moe extra-args…
  local id=$1 ncmoe=$2; shift 2
  LLAMA_ARG_LAZY_MODE=auto "$ROOT/engine/bin/llama-perplexity" -m "$MODELS/$id/$(first "$id")" -f "$TEXT" \
    -c 512 --chunks "$CHUNKS" -ngl 999 --n-cpu-moe "$ncmoe" -fa on -t 12 -ub 512 -b 512 "$@"
}

BASE="$OUT/$REF.kld"
if [ ! -s "$BASE" ]; then
  echo "== reference: $REF"
  run "$REF" "$REF_CPU" --kl-divergence-base "$BASE" 2>&1 | tee "$OUT/$REF.log" | grep -E "Final estimate|error" || true
fi
echo "== $TEST against $REF"
run "$TEST" "$TEST_CPU" --kl-divergence-base "$BASE" --kl-divergence 2>&1 | tee "$OUT/$TEST.log" \
  | grep -E "Mean PPL|Mean    KLD|Median  KLD|Same top p|Mean    Δp|error" || true
