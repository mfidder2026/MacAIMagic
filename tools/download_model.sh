#!/bin/bash
# Download one model from models.json (all shards in parallel, resumable) plus its vision projector, and verify sha256.
# Usage: download_model.sh <model-id> [models-folder]
#   default folder: ~/Library/Application Support/MacDeepSeek/models   (the model lands in <folder>/<model-id>/)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/models.json"
ID="${1:?usage: download_model.sh <model-id> [models-folder]}"
ROOT="${2:-$HOME/Library/Application Support/MacDeepSeek/models}"

# "<folder>\t<local>\t<size>\t<sha256>\t<url>" per file, from the manifest
LIST="$(/usr/bin/python3 -I - "$MANIFEST" "$ID" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
model = next((x for x in m["models"] if x["id"] == sys.argv[2]), None)
if model is None:
    sys.exit("unknown model: " + sys.argv[2] + " (known: " + ", ".join(x["id"] for x in m["models"]) + ")")
for f in model["files"]:
    print("\t".join([model["id"], f["local"], str(f["size"]), f["sha256"], f["url"]]))
v = next((x for x in m.get("vision", []) if x["id"] == model.get("vision")), None)
if v:
    print("\t".join(["vision", v["local"], str(v["size"]), v["sha256"], v["url"]]))
PY
)" || exit 1

fetch() {
  local dir="$ROOT/$1" name=$2 size=$3 sha=$4 url=$5
  local f="$dir/$name"
  mkdir -p "$dir"
  if [ -f "$f.ok" ]; then echo "$name: already verified"; return 0; fi
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    have=$(stat -f %z "$f" 2>/dev/null || echo 0)
    [ "$have" -ge "$size" ] && break
    curl -sSL --fail -C - --retry 5 --retry-delay 5 -o "$f" "$url" && break
    echo "$name: retry $attempt"; sleep 5
  done
  have=$(stat -f %z "$f" 2>/dev/null || echo 0)
  [ "$have" -eq "$size" ] || { echo "$name: size $have != $size"; return 1; }
  echo "$name: verifying sha256"
  got=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [ "$got" = "$sha" ] || { echo "$name: CHECKSUM MISMATCH ($got)"; return 1; }
  touch "$f.ok"; echo "$name: OK"
}

pids=()
while IFS=$'\t' read -r dir name size sha url; do
  fetch "$dir" "$name" "$size" "$sha" "$url" & pids+=($!)
done <<< "$LIST"
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ $rc -eq 0 ] && echo "ALL FILES VERIFIED: $ID" || echo "DOWNLOAD INCOMPLETE: $ID"
exit $rc
