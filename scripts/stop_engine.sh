#!/bin/bash
# Stop the engine started by run_engine.sh and wait until it is really gone: a model with 100+ GB wired takes a while to
# release its memory, and a new engine started before that fights the old one for memory (minutes of swapping).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkill -INT -f "$ROOT/engine/bin/llama-server" || exit 0
for _ in $(seq 1 120); do pgrep -f "$ROOT/engine/bin/llama-server" >/dev/null || exit 0; sleep 1; done
pkill -KILL -f "$ROOT/engine/bin/llama-server"
for _ in $(seq 1 60); do pgrep -f "$ROOT/engine/bin/llama-server" >/dev/null || exit 0; sleep 1; done
