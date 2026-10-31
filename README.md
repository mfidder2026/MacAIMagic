# MacDeepSeek

Run **DeepSeek-V4.1-Flash-1017** (748B parameters) and **GLM-5.3-Flash** (321B parameters), two of the largest open
mixture-of-experts models, fully locally on an Apple Silicon Mac with 128 GB of unified memory. MacDeepSeek is a native
macOS app with live performance charts. You can chat with the models, upload images, let them search the web, compare
them side by side, and use them as an OpenAI- or Anthropic-compatible API (for example from Claude Code).

![Live dashboard](docs/screenshots/live.png)

> All screenshots show real answers and real measurements on a MacBook Pro M3 Max (128 GB).
> The app's interface is in Dutch for now.

## Models

| Model | Download | In memory | Writing | Prompt reading |
|---|---|---|---|---|
| **DeepSeek-V4.1-Flash Compact**: 748B MoE, experts 1.6 bit, attention 8 bit | 278 GB | fits (115 GB) | **19.6–20.1 tok/s** | ~160–175 tok/s |
| **GLM-5.3-Flash Compact**: 321B MoE, experts 2–3 bit | 110 GB | fits (109 GB) | **19.9–20.4 tok/s** | ~175–180 tok/s |
| **DeepSeek-V4.1-Flash Q4**: 4 bit, close to the original FP4 experts | 502 GB | streams from the SSD | being measured | being measured |
| **GLM-5.3-Flash Q4**: 4 bit | 201 GB | streams from the SSD | being measured | being measured |

Measured on a MacBook Pro **M3 Max, 128 GB**, macOS 27, with 64K context, vision on, and the default macOS GPU memory
limit. *Writing* is decode speed. *Prompt reading* is prefill speed on a 2,500-token prompt.

- **Compact** versions keep everything a token needs in memory. They are the fast choice.
- **Q4** versions are close to the original weights, but larger than memory: the experts that don't fit are read from
  the SSD while the model writes. They are slower and more accurate.

## Why a Mac

Projects like [PolyStrata](https://github.com/VecSzn/PolyStrata) run very large MoE models on PCs with limited video
memory. They keep the busiest experts on the GPU and the rest in RAM or on the SSD, and copy experts across the PCIe
bus as needed. None of them runs these models on a Mac.

A Mac doesn't need that split. CPU and GPU share one pool of unified memory, so on a 128 GB Mac a whole compact model
(110–115 GB) stays in memory and the GPU reads it directly. Nothing is copied to a video card. For models larger than
memory, the GPU keeps a fixed set of layers, and macOS's page cache holds the experts that are actually used. The rest
comes from the internal SSD.

## Screenshots

| Chat with web search | The model reads an image |
|---|---|
| ![Chat with web search](docs/screenshots/chat-search.png) | ![The model reads a screenshot](docs/screenshots/chat-image.png) |

| Models | Side-by-side comparison |
|---|---|
| ![Models](docs/screenshots/models.png) | ![Compare](docs/screenshots/compare.png) |

## Features

- **Live dashboard**: a speed gauge and real-time charts of tokens/s, GPU and CPU load, memory and SSD reads
- **Four models**, each with a download card (resumable, sha256-checked), a memory plan and one-click start
- **Compare**: measure every downloaded model the same way and see the results side by side
- Streaming chat with markdown and code blocks (with a copy button)
- **Thinking** on/off, with a collapsible chain of thought and a reasoning-effort setting
- **Images**: button, drag and drop, or paste (⌘V)
- **Web search**: the model calls `web_search` and `fetch_url` by itself. The app runs them (DuckDuckGo, or Brave Search
  with your own API key) and shows each step and the sources.
- Conversations are saved locally
- Local API on `http://127.0.0.1:8080`: OpenAI (`/v1`), Anthropic (`/v1/messages`) and Responses (`/v1/responses`)

## Requirements

- Apple Silicon Mac with **128 GB** unified memory (tested on M3 Max)
- macOS 14 or later
- Disk space: 110–502 GB per model (see the table above)
- To build from source: Xcode Command Line Tools and CMake (`brew install cmake`)

## Installation

### 1. Get the app

Either download the ready-made build from [`RELEASE/`](RELEASE/), or build it yourself (see below).

The release build is ad-hoc signed, not notarized. The first time, right-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine MacDeepSeek.app
```

### 2. Download one or more models

The models are **not** included in this repository. Each one is several GGUF files plus an optional vision file. There
are three ways to get them:

- **In the app:** Modellen → **Download** on a model's card. It downloads in parallel, resumes after interruptions and
  checks every file's sha256.
- **With the script:** `tools/download_model.sh <model-id> [folder]`, for example
  `tools/download_model.sh glm-5.3-flash-compact`.
- **By hand:** the download URLs, file names, sizes and checksums are in [`tools/models.json`](tools/models.json).

Put each model in its own folder named after its id, and the vision files in `vision/`:

```
models/
├── deepseek-v4.1-flash-compact/   deepseek-v4.1-flash-compact-00001-of-00005.gguf …
├── glm-5.3-flash-compact/         glm-5.3-flash-compact-00001-of-00004.gguf …
└── vision/                        deepseek-v4.1-vision.gguf, glm-5.3-vision.gguf
```

The default location is `~/Library/Application Support/MacDeepSeek/models/`. To use another folder, choose it in the app
under Modellen → Modelmap → **Kies map…**.

### 3. Start

Open the app, choose a model under **Modellen** and press **Start**. Close large programs first, because a compact model
uses about 115–120 of the 128 GB. Optionally, press **Verhoog GPU-limiet** to let the GPU wire more memory. This runs
`sysctl iogpu.wired_limit_mb`, asks for your password, and lasts until the next restart.

## Building from source

```sh
git clone https://github.com/mfidder2026/MacDeepSeek.git
cd MacDeepSeek
brew install cmake
./scripts/build_engine.sh     # fetches llama.cpp at a pinned commit, applies the patch, builds with Metal (~5 min)
./scripts/make_app.sh         # builds dist/MacDeepSeek.app with the engine inside
open dist/MacDeepSeek.app
```

Run the engine without the app: `./scripts/run_engine.sh <model-id> [cpu-moe-layers]`. Then benchmark it with
`python3 tools/bench.py`.

To measure quality, compare a compact model with its Q4 version (next-token agreement and KL divergence):
`tools/quality.sh deepseek` or `tools/quality.sh glm`.

Tests: `cd App && swift test`. The engine tests run only when you ask for them:
`MACDEEPSEEK_ENGINE_TEST=1 swift test` with the engine running, or `MACDEEPSEEK_BENCH=<ids> swift test` with it stopped.

## Using the API

While the engine runs, other programs can use the model:

```sh
# Claude Code with the local model
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude

# any OpenAI-compatible client
curl http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello!"}]}'
```

The API listens on this Mac only. To reach it from other machines, set the address to `0.0.0.0` **and** an API key in
the settings.

## How it works

**Engine.** [llama.cpp](https://github.com/ggml-org/llama.cpp), pinned to commit `ddf48f8`, which supports
`deepseek41` and `glm5-next` natively, built with Metal. On top of that,
[`patches/0001-deepseek41-split-engram.patch`](patches/0001-deepseek41-split-engram.patch) lets it load DeepSeek GGUFs that
store the Engram n-gram tables differently:

- the Engram metadata is named `engram.*` instead of `ple.*`, with the bucket counts stored as u32;
- the tables are split into one tensor per Engram layer, with local offsets;
- the `hash_layer_count` key is missing. V4.1 has no hash layers, so it now defaults to 0.

**Memory plan.** The app reads the GGUF headers and decides where each part goes:

| Part | Where |
|---|---|
| Dense weights (attention, shared experts, router, hyper-connections) | GPU |
| Routed experts | GPU, as many layers as fit under the GPU limit; the first layers run on the CPU from the page cache |
| Experts that don't fit in memory at all (Q4) | SSD, through the page cache, as they are needed |
| DeepSeek's Engram tables (161–203 GB) | SSD; a few rows per token are read on demand |
| KV cache and compute buffers | GPU |

**Tuning.** `--ubatch-size 1024` reads prompts about 20% faster than the default of 512. 2048 makes the compute buffers
too big: memory overflows and writing drops from 20 to 3 tokens/s.

## Project layout

```
App/          SwiftUI app (Swift package) and tests
patches/      llama.cpp patch and pinned commit
scripts/      build_engine.sh, make_app.sh, run_engine.sh, make_icon.swift
tools/        models.json, download_model.sh, bench.py, quality.sh, gguf_peek.py
docs/         screenshots, Dutch README
RELEASE/      ready-made app build
```

## Roadmap

- Faster prompt reading (Metal kernels for low-bit experts at large batch sizes)
- An expert cache that learns which experts a conversation uses (for the Q4 models)
- English interface

## Credits and licenses

MacDeepSeek is MIT-licensed (see [LICENSE](LICENSE)). It builds on:

- [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) (MIT): the inference engine, bundled in the release build
- [DeepSeek-V4.1-Flash-1017](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017) (MIT), by DeepSeek
- [GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) (MIT), by Z.ai
- The quantized GGUF files are downloaded from Hugging Face from their publishers; see [`tools/models.json`](tools/models.json)

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
