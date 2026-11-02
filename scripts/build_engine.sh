#!/bin/bash
# Build the MacAIMagic engine: llama.cpp at a pinned commit + MacAIMagic patches, Metal, static binaries.
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

# GGML_NATIVE=OFF: portable, Apple clang targets the M1 baseline, so the engine runs on every Apple Silicon Mac
# GGML_RPC=ON: several Macs as one (the helper Mac runs ggml-rpc-server, the main Mac uses --rpc)
# LLAMA_OPENSSL=OFF: otherwise the binaries link Homebrew's OpenSSL and do not start on a Mac without it;
# the engine needs no HTTPS (the app downloads models with curl)
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_RPC=ON \
  -DBUILD_SHARED_LIBS=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF
cmake --build build -j "$(sysctl -n hw.ncpu)" --target llama-server llama-bench llama-cli llama-perplexity ggml-rpc-server

# every binary may only use libraries that come with macOS, or it fails on another Mac
for b in build/bin/llama-server build/bin/llama-bench build/bin/llama-cli build/bin/llama-perplexity build/bin/ggml-rpc-server; do
  if otool -L "$b" | tail -n +2 | awk '{print $1}' | grep -v -E '^/(System|usr/lib)/'; then
    echo "fout: $(basename "$b") gebruikt een bibliotheek die niet bij macOS hoort (zie hierboven)"; exit 1
  fi
done

mkdir -p "$ROOT/engine/bin"
cp build/bin/llama-server build/bin/llama-bench build/bin/llama-cli build/bin/llama-perplexity build/bin/ggml-rpc-server "$ROOT/engine/bin/"
echo "engine klaar: $ROOT/engine/bin"
