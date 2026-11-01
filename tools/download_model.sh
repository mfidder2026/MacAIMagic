#!/bin/bash
# Download one model from models.json (all shards in parallel, resumable) plus its vision projector, and verify sha256.
# Usage: download_model.sh <model-id> [models-folder]
#   default folder: ~/Library/Application Support/MacAIMagic/models   (the model lands in <folder>/<model-id>/)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/models.json"
ID="${1:?usage: download_model.sh <model-id> [models-folder]}"
ROOT="${2:-$HOME/Library/Application Support/MacAIMagic/models}"

# "<folder>\t<local>\t<size>\t<sha256>\t<url>" per file, from the manifest
LIST="$(/usr/bin/python3 -I - "$MANIFEST" "$ID" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
model = next((x for x in m["models"] if x["id"] == sys.argv[2]), None)
if model is None:
    sys.exit("unknown model: " + sys.argv[2] + " (known: " + ", ".join(x["id"] for x in m["models"]) + ")")
for f in model["files"]:
    stamp = ",".join(str(n) for n in f.get("stamp", []))
    print("\t".join([model["id"], f["local"], str(f["size"]), f["sha256"], f["url"], stamp]))
d = model.get("draft")
if d:
    print("\t".join([model["id"], d["local"], str(d["size"]), d["sha256"], d["url"], ""]))
v = next((x for x in m.get("vision", []) if x["id"] == model.get("vision")), None)
if v:
    print("\t".join(["vision", v["local"], str(v["size"]), v["sha256"], v["url"], ""]))
PY
)" || exit 1

# A shard published on its own (as "1 of 1") gets its place in the set written into its header: split.no / split.count.
stamp_split() {  # file no count
  /usr/bin/python3 -I - "$1" "$2" "$3" <<'PY'
import struct, sys
path, idx, cnt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, "r+b") as f:
    head = f.read(1 << 24)
    for key, val in ((b"split.no", idx - 1), (b"split.count", cnt)):
        f.seek(head.index(struct.pack("<Q", len(key)) + key + struct.pack("<I", 2)) + len(key) + 12)
        f.write(struct.pack("<H", val))
PY
}

fetch() {
  local dir="$ROOT/$1" name=$2 size=$3 sha=$4 url=$5 stamp=${6:-}
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
  if [ -n "$stamp" ]; then stamp_split "$f" "${stamp%,*}" "${stamp#*,}" && echo "$name: stamped as shard ${stamp%,*} of ${stamp#*,}"; fi
  touch "$f.ok"; echo "$name: OK"
}

pids=()
while IFS=$'\t' read -r dir name size sha url stamp; do
  fetch "$dir" "$name" "$size" "$sha" "$url" "$stamp" & pids+=($!)
done <<< "$LIST"
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ $rc -eq 0 ] && echo "ALL FILES VERIFIED: $ID" || echo "DOWNLOAD INCOMPLETE: $ID"
exit $rc
