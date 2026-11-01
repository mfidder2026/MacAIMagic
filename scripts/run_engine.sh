#!/bin/bash
# Start the engine from the command line with the same arguments the app uses (log: engine-test.log).
# Usage: run_engine.sh [model-id] [n-cpu-moe] [ctx-size]      extra llama-server flags: EXTRA_ARGS="…"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="${1:-deepseek-v4.1-flash-compact}"
MODELS="${MODELS_DIR:-$HOME/Library/Application Support/MacDeepSeek/models}"

# first shard and vision file of this model, from models.json
read -r FIRST VISION < <(/usr/bin/python3 -I - "$ROOT/tools/models.json" "$ID" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
model = next(x for x in m["models"] if x["id"] == sys.argv[2])
vision = next((v["local"] for v in m["vision"] if v["id"] == model.get("vision")), "")
print(model["files"][0]["local"], vision)
PY
)
[ -n "$FIRST" ] || { echo "unknown model: $ID"; exit 1; }
VISION_ARGS=()
[ -n "$VISION" ] && [ -f "$MODELS/vision/$VISION" ] && VISION_ARGS=(--mmproj "$MODELS/vision/$VISION")

cd "$ROOT"
# never start next to another engine (the app's, for example): two models do not fit in memory
if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1 || pgrep -x llama-server >/dev/null; then
  echo "er draait al een engine (poort 8080); stop die eerst" | tee engine-test.log; exit 1
fi
LLAMA_ARG_LAZY_MODE=auto exec "$ROOT/engine/bin/llama-server" \
  --model "$MODELS/$ID/$FIRST" "${VISION_ARGS[@]}" \
  --host 127.0.0.1 --port 8080 --ctx-size "${3:-65536}" \
  --n-gpu-layers 999 --n-cpu-moe "${2:-2}" --flash-attn on --fit off \
  --threads 12 --parallel 1 --jinja --reasoning-format deepseek --metrics \
  --ubatch-size 1024 --batch-size 2048 --alias "$ID" $EXTRA_ARGS > engine-test.log 2>&1
