#!/bin/bash
# Download DeepSeek-V4.1-Flash-1017 Maya-XS (5 GGUF shards, 277 GB) + vision projector (1 GB) with resume, in parallel, and verify sha256.
# Usage: download_model.sh [target-dir]
set -u
REPO="https://huggingface.co/peasantsmith/DeepSeek-V4.1-Flash-1017-Maya-GGUF/resolve/main/Maya-XS"
VISION="https://huggingface.co/unsloth/DeepSeek-V4.1-Flash-1017-GGUF/resolve/main"
DIR="${1:-$HOME/Library/Application Support/MacDeepSeek/models/Maya-XS}"
mkdir -p "$DIR"
FILES=(
  "DeepSeek-V4.1-Flash-1017-Maya-XS-IQ1_S-00001-of-00005.gguf 47781530400 a0cb7966afd68bc35c46f78018d1fa1d2e4bcbe3c3baf39f60cd1733ed9ad7e5"
  "DeepSeek-V4.1-Flash-1017-Maya-XS-IQ1_S-00002-of-00005.gguf 47775748128 ba5afb43adfc667436ebcfbd82d25411fa2843ee7e1d877290611cd60f93cca1"
  "DeepSeek-V4.1-Flash-1017-Maya-XS-IQ1_S-00003-of-00005.gguf 19784230848 1482443bb4957c8d2f005ded365445f98558ff05c50674f9ee9a96ddabc122a4"
  "DeepSeek-V4.1-Flash-1017-Maya-XS-IQ1_S-00004-of-00005.gguf 80641295472 0d93315942c523d82f6dbc0a6e0e1751548e309f3963f96b82f92e8f9bc52e36"
  "DeepSeek-V4.1-Flash-1017-Maya-XS-IQ1_S-00005-of-00005.gguf 80643503412 39bbc8cde8b17604fed9a7ba7fc6bc9c5e72e34733657943ac049b4b9ca2d340"
  "mmproj-F16.gguf 971004064 dad8ad13f1d9a25757e121592d7b4f8ca83620d1172048004998b7c0b964b18e"
)
fetch() {
  local name=$1 size=$2 sha=$3 f="$DIR/$1"
  if [ -f "$f.ok" ]; then echo "$name: already verified"; return 0; fi
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    have=$(stat -f %z "$f" 2>/dev/null || echo 0)
    [ "$have" -ge "$size" ] && break
    local base="$REPO"; [[ "$name" == mmproj* ]] && base="$VISION"
    curl -sSL --fail -C - --retry 5 --retry-delay 5 -o "$f" "$base/$name" && break
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
for e in "${FILES[@]}"; do fetch $e & pids+=($!); done
rc=0; for p in "${pids[@]}"; do wait $p || rc=1; done
[ $rc -eq 0 ] && echo "ALL SHARDS VERIFIED in $DIR" || echo "DOWNLOAD INCOMPLETE"
exit $rc
