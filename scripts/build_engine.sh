#!/bin/bash
# Build the MacDeepSeek engine: llama.cpp at a pinned commit + MacDeepSeek patches, Metal, static binaries.
# Output: engine/bin/{llama-server,llama-bench,llama-cli}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/llama.cpp"
COMMIT="$(cat "$ROOT/patches/LLAMA_CPP_COMMIT")"

command -v cmake >/dev/null || { echo "cmake ontbreekt: brew install cmake"; exit 1; }
xcrun --find metal >/dev/null 2>&1 || echo "let op: Metal-compiler niet gevonden; de shaders worden runtime gecompileerd"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/ggml-org/llama.cpp.git "$SRC"
fi
cd "$SRC"
if [ "$(git rev-parse HEAD)" != "$COMMIT" ]; then
  git fetch --depth 200 origin master || true
  git checkout -q "$COMMIT"
fi
# apply each patch once (idempotent)
for p in "$ROOT"/patches/*.patch; do
  if git apply --reverse --check "$p" 2>/dev/null; then
    echo "patch al toegepast: $(basename "$p")"
  else
    git apply "$p" && echo "patch toegepast: $(basename "$p")"
  fi
done

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=ON \
  -DBUILD_SHARED_LIBS=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF
cmake --build build -j "$(sysctl -n hw.ncpu)" --target llama-server llama-bench llama-cli

mkdir -p "$ROOT/engine/bin"
cp build/bin/llama-server build/bin/llama-bench build/bin/llama-cli "$ROOT/engine/bin/"
echo "engine klaar: $ROOT/engine/bin"
