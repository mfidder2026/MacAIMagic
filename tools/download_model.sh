#!/bin/bash
# Download one model from models.json (all shards in parallel, resumable) plus its vision projector, and verify sha256.
# Usage: download_model.sh <model-id> [models-folder]
#   An .ok beside a file holds the sha256 of that file as it is on disk. One that differs from the catalog's means another
#   version: it is downloaded again. An empty .ok (before 1.9.12) is trusted on the file's size: reading hundreds of GB to
#   check them made a Mac unusable for minutes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/models.json"
ID="${1:?usage: download_model.sh <model-id> [models-folder]}"
ROOT="${2:-$HOME/Library/Application Support/MacAIMagic/models}"

# "<folder>\t<local>\t<size>\t<sha256>\t<url>\t<stamp>" per file, from the manifest.
# JavaScript through osascript, which every Mac has (python3 needs the developer tools on a clean Mac).
LIST="$(/usr/bin/osascript -l JavaScript - "$MANIFEST" "$ID" <<'JS'
ObjC.import("Foundation")
function run(argv) {
  const m = JSON.parse($.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js)
  const all = m.models.concat(m.images || [])
  const model = all.find(x => x.id === argv[1])
  if (!model) throw new Error("unknown model: " + argv[1] + " (known: " + all.map(x => x.id).join(", ") + ")")
  const rows = model.files.map(f => [model.id, f.local, f.size, f.sha256, f.url, (f.stamp || []).join(",")])
  const d = model.draft
  if (d) rows.push([model.id, d.local, d.size, d.sha256, d.url, ""])
  const v = (m.vision || []).find(x => x.id === model.vision)
  if (v) rows.push(["vision", v.local, v.size, v.sha256, v.url, ""])
  return rows.map(r => r.join("\t")).join("\n")
}
JS
)" || exit 1

# A shard published on its own (as "1 of 1") gets its place in the set written into its header: split.no / split.count.
stamp_split() {  # file no count
  /usr/bin/osascript -l JavaScript - "$1" "$2" "$3" <<'JS'
ObjC.import("Foundation")
// bytes as NSData: every char code 0-255 is one byte in ISO Latin 1
const data = s => $(s).dataUsingEncoding($.NSISOLatin1StringEncoding)
const le = (n, width) => Array.from({length: width}, (_, i) => String.fromCharCode(Math.floor(n / 2 ** (8 * i)) % 256)).join("")
function run(argv) {
  const [path, idx, cnt] = [argv[0], parseInt(argv[1]), parseInt(argv[2])]
  const h = $.NSFileHandle.fileHandleForUpdatingAtPath(path)
  const head = h.readDataOfLength(1 << 24)
  for (const [key, val] of [["split.no", idx - 1], ["split.count", cnt]]) {
    // the key as GGUF writes it: uint64 length, the name, uint32 type 2 (uint16), then the value
    // the bridge hands the location over as a string
    const at = Number(head.rangeOfDataOptionsRange(data(le(key.length, 8) + key + le(2, 4)), 0, $.NSMakeRange(0, head.length)).location)
    if (!(at < head.length)) throw new Error(key + " not found in " + path)
    h.seekToFileOffset(at + key.length + 12)
    h.writeData(data(le(val, 2)))
  }
  h.closeFile
}
JS
}

# The server names a file's size before a byte is written: finding out after 111 GB helps nobody.
# Exit 3: the maker replaced or removed a file, and no attempt changes that. No answer at all is no verdict: the download tries.
preflight() {  # name size url
  local head status linked
  head="$(curl -sI --max-time 30 "$3" 2>/dev/null | tr -d '\r')" || return 0
  status="$(printf '%s\n' "$head" | awk 'NR==1 {print $2}')"
  case "$status" in
    401|403|404|410) echo "$1: REPLACED (status $status)"; return 3 ;;
  esac
  linked="$(printf '%s\n' "$head" | awk -F': ' 'tolower($1)=="x-linked-size" {print $2}')"
  [ -z "$linked" ] && [ "$status" = 200 ] && linked="$(printf '%s\n' "$head" | awk -F': ' 'tolower($1)=="content-length" {print $2}')"
  if [ -n "$linked" ] && [ "$linked" != "$2" ]; then echo "$1: REPLACED (size $linked instead of $2)"; return 3; fi
  return 0
}

fetch() {
  local dir="$ROOT/$1" name=$2 size=$3 sha=$4 url=$5 stamp=${6:-}
  local f="$dir/$name"
  mkdir -p "$dir"
  if [ -f "$f.ok" ]; then
    ok="$(cat "$f.ok")"
    if [ "$ok" = "$sha" ]; then echo "$name: already verified"; return 0; fi
    have=$(stat -f %z "$f" 2>/dev/null || echo 0)
    # checked before 1.9.12, when the .ok stayed empty: its size says it is the catalog's file
    if [ -z "$ok" ] && [ "$have" -eq "$size" ]; then echo "$sha" > "$f.ok"; echo "$name: OK (checked before)"; return 0; fi
    echo "$name: another version on disk; downloading the catalog's"
    rm -f "$f" "$f.ok"
  fi
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    have=$(stat -f %z "$f" 2>/dev/null || echo 0)
    [ "$have" -ge "$size" ] && break
    curl -sSL --fail -C - --retry 5 --retry-delay 5 -o "$f" "$url" && break
    echo "$name: retry $attempt"; sleep 5
  done
  have=$(stat -f %z "$f" 2>/dev/null || echo 0)
  [ "$have" -eq "$size" ] || { echo "FAILED $name: size $have != $size"; return 1; }
  echo "$name: verifying sha256"
  got=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [ "$got" = "$sha" ] || { echo "FAILED $name: checksum mismatch ($got)"; return 1; }
  if [ -n "$stamp" ]; then stamp_split "$f" "${stamp%,*}" "${stamp#*,}" && echo "$name: stamped as shard ${stamp%,*} of ${stamp#*,}"; fi
  echo "$sha" > "$f.ok"; echo "$name: OK"
}

while IFS=$'\t' read -r dir name size sha url stamp; do
  [ "$(cat "$ROOT/$dir/$name.ok" 2>/dev/null)" = "$sha" ] && continue
  preflight "$name" "$size" "$url" || exit 3
done <<< "$LIST"

pids=()
while IFS=$'\t' read -r dir name size sha url stamp; do
  fetch "$dir" "$name" "$size" "$sha" "$url" "$stamp" & pids+=($!)
done <<< "$LIST"
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ $rc -eq 0 ] && echo "ALL FILES VERIFIED: $ID" || echo "DOWNLOAD INCOMPLETE: $ID"
exit $rc
