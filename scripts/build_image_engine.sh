#!/bin/bash
# Build the image engine at the commit the Windows version is built with, for Metal.
# Output: engine/bin/image-engine. Say "the image engine" in the app and the docs; its real name is only here and in the notices.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/image-engine"
COMMIT=58bb3c1b1cd4749e94e39f537e9adfce295dcaee

command -v cmake >/dev/null || { echo "cmake ontbreekt: brew install cmake"; exit 1; }
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  git clone --filter=blob:none https://github.com/leejet/stable-diffusion.cpp "$SRC"
fi
git -C "$SRC" checkout -q "$COMMIT"
git -C "$SRC" submodule update --init --recursive --depth 1

cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DSD_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF \
  -DBUILD_SHARED_LIBS=OFF -DSD_BUILD_SHARED_LIBS=OFF
cmake --build "$SRC/build" -j "$(sysctl -n hw.ncpu)" --target sd-cli

BIN="$(find "$SRC/build" -type f -name sd-cli -perm -u+x | head -1)"
# only libraries that come with macOS, or it fails on another Mac
if otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -v -E '^/(System|usr/lib)/'; then
  echo "fout: de beeldengine gebruikt een bibliotheek die niet bij macOS hoort (zie hierboven)"; exit 1
fi
mkdir -p "$ROOT/engine/bin"
cp "$BIN" "$ROOT/engine/bin/image-engine"
echo "beeldengine klaar: $ROOT/engine/bin/image-engine"
