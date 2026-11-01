#!/bin/bash
# For a model larger than memory: try several splits between GPU layers (fixed) and page cache (adaptive)
# and measure each. Results: build/tune-<model-id>.txt
# Usage: stream_tune.sh <model-id> <cpu-moe-layers…>     e.g. stream_tune.sh deepseek-v4.1-flash-q4 26 30 33 37 40
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ID="${1:?usage: stream_tune.sh <model-id> <cpu-moe-layers…>}"; shift
export LLAMA_MMAP_PREFETCH=0   # the model is larger than memory: no read-ahead of the whole file
export EXTRA_ARGS="--no-repack $EXTRA_ARGS"   # keep CPU experts mapped from the file, not repacked into RAM
OUT="$ROOT/build/tune-$ID.txt"
mkdir -p "$ROOT/build"

for N in "$@"; do
  "$ROOT/scripts/stop_engine.sh"
  echo "=== $ID, cpu-moe layers $N, $(date +%H:%M)" | tee -a "$OUT"
  "$ROOT/scripts/run_engine.sh" "$ID" "$N" 32768 &
  /usr/bin/python3 -I - "$OUT" <<'PY'
import json, sys, time, urllib.request
out = open(sys.argv[1], "a")
URL = "http://127.0.0.1:8080"
t0 = time.time()
while True:
    try:
        if urllib.request.urlopen(URL + "/health", timeout=2).status == 200: break
    except Exception: pass
    if time.time() - t0 > 2700: print("not ready", file=out); sys.exit()
    time.sleep(2)
def chat(text, n):
    body = {"messages": [{"role": "user", "content": text}], "max_tokens": n, "temperature": 0.7,
            "chat_template_kwargs": {"enable_thinking": False}}
    r = urllib.request.Request(URL + "/v1/chat/completions", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=3600))["timings"]
line = f"load {time.time() - t0:.0f} s"
# writing, three rounds: the page cache warms up as the conversation goes on
for i, topic in enumerate(["een vuurtorenwachter", "de Afsluitdijk", "een robot die leert koken"]):
    t = chat(f"Schrijf een verhaal van 250 woorden over {topic}.", 256)
    line += f" | decode{i + 1} {t['predicted_per_second']:.2f} tok/s"
t = chat(f"[{time.time()}] " + "Vat samen: " + " ".join(f"Zin {i} over techniek, natuur en geschiedenis in Nederland." for i in range(120)), 16)
line += f" | prompt {t['prompt_per_second']:.1f} tok/s ({t['prompt_n']} tok)"
print(line, file=out); print(line)
PY
done
"$ROOT/scripts/stop_engine.sh"
