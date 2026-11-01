# Research notes

Measurements and findings behind MacDeepSeek's choices, all on a MacBook Pro M3 Max with 128 GB.

## 1. Speculative decoding with MTP (learned from MTPLX)

MTPLX (by Youssofal, installed on this Mac as MTPLX.app 2.12.2) is an MLX-based app that runs mid-size models (Qwen3.6-35B-A3B, Qwen3.8-27B,
Qwen3.8-Flash-Next, Gemma 4) very fast on Apple Silicon. Its own logs on this Mac show these decode speeds (median):

| Model in MTPLX | Writing |
|---|---|
| Qwen3.6-35B-A3B | 67–82 tok/s |
| Qwen3.8-27B | 35–44 tok/s |
| Qwen3.8-Flash-Next (Bare Speed, 4 bit) | 41 tok/s |

Its main trick is **multi-token prediction (MTP)**: a small head guesses the next few tokens, and the big model checks
them all in one pass. The answer stays exactly the same; only the speed changes. MTPLX tunes how many tokens it guesses
ahead per machine and per kind of text.

GLM-5.3-Flash has an MTP layer built in, and Qwen3.8-Flash-Next ships one as a separate file. llama.cpp supports both
(`--spec-type draft-mtp`). Measured on GLM-5.3-Flash Compact:

| Kind of text | No MTP | MTP, 3 ahead | MTP, 2 ahead |
|---|---|---|---|
| Code (temperature 0) | ~20 tok/s | 28.5 tok/s | **29.3 tok/s (+44%)** |
| Explanation (temperature 1.0) | ~20 tok/s | – | **24.7 tok/s (+20%)** |
| Creative story (temperature 0.7) | ~20 tok/s | 17.0 tok/s | 19.5 tok/s (same) |

And on Qwen3.8-Flash-Next Q4, with its separate MTP file (2 ahead):

| Kind of text | No MTP | MTP, 2 ahead |
|---|---|---|
| Code (temperature 0) | 33.3 tok/s | **54.9 tok/s (+65%)** |
| Explanation (temperature 1.0) | 33.1 tok/s | **40.3 tok/s (+22%)** |
| Creative story (temperature 0.7) | 32.8 tok/s | 34.4 tok/s (+5%) |
| Prompt reading (2,750 tokens) | 437 tok/s | 451 tok/s |

For reference, MTPLX's own logs show a median of 41 tok/s for Qwen3.8-Flash-Next on this Mac (a different 4-bit file,
and the user's own chats rather than these prompts), so this is not a strict head-to-head; it does show that llama.cpp
with MTP is at least as fast on this model.

With 3 tokens ahead, too many guesses on creative text are rejected and checking them costs more than it saves. MacDeepSeek
therefore uses MTP with 2 tokens ahead for the models that have an MTP head.

DeepSeek-V4.1 has no MTP head in these files; its own draft model (DSpark, 8 GB) does not fit next to the 115 GB compact
model.

## 2. Models larger than memory (Q4)

The Q4 versions are close to the original weights, but on a 128 GB Mac part of their experts must come from the SSD.

| Model | Experts | In memory | From the SSD |
|---|---|---|---|
| DeepSeek-V4.1-Flash Q4 | 289 GB | ~110 GB | ~173 GB |
| GLM-5.3-Flash Q4 | 190 GB | ~110 GB | ~75 GB |

What we found with llama.cpp's standard path (the experts that don't fit stay memory-mapped from the file):

- **Weight repacking must be off.** llama.cpp repacks MXFP4 experts for faster CPU math, into ordinary RAM. For 238 GB
  of CPU experts that never fits: the Mac swaps (150 GB swapped out in our test) and the process is killed. `--no-repack`
  keeps them mapped.
- **Whole-file read-ahead must be off.** At load, llama.cpp asks macOS to read the entire file ahead (`MADV_WILLNEED`).
  For a model larger than memory that reads hundreds of GB and evicts itself. Our patch adds `LLAMA_MMAP_PREFETCH=0`.
- **Even then, mmap streaming is slow: ~2.8 tok/s for DeepSeek Q4 and ~2.2 tok/s for GLM Q4** (writing), ~9 tok/s
  prompt reading. macOS pages the experts in as 16–22 KB page faults: the SSD delivers ~1.2 GB/s of its ~6 GB/s,
  because the reads are small and serial. (A first DeepSeek measurement of 0.6 tok/s was with the misread Engram table
  below.)

- **DeepSeek Q4 wrote nonsense at first.** Its Engram table shard is published as "MXFP8", stored with ggml type id 43.
  Standard llama.cpp uses id 43 for F8_E4M3 (no block scales), so it read the table wrongly: the sizes give it away
  (202.8 GB for 196.6 G values is 33 bytes per 32, the MXFP8 layout). The fix is the same table in Q6_K, which the
  publisher offers as a drop-in shard: `tools/models.json` downloads that one and stamps its header as shard 8 of 9.

So a 128 GB Mac cannot run the Q4 versions usefully with mmap. What would help is what the PC projects do with VRAM:
an **expert cache** that, right after the router picks the experts of a layer, reads the missing ones with large
parallel reads (several MB each, many at once), and keeps the experts a conversation uses most in memory. Even then the
SSD caps the speed: at 1.5–2.5 GB per token from a ~6 GB/s SSD, expect at most 2–4 tok/s for DeepSeek Q4.

### How much quality do the compact versions cost?

`tools/quality.sh` runs the same text (llama.cpp's documentation, 12 chunks of 512 tokens) through the Q4 version and saves
its token probabilities, then measures the compact version against them:

| Compact against Q4 | Same next token | Perplexity | KL divergence |
|---|---|---|---|
| GLM-5.3-Flash | **84.1%** | +11.8% (4.37 vs 3.91) | 0.23 |
| DeepSeek-V4.1-Flash | **84.5%** | +32% (3.50 vs 2.65) | 0.30 |

Both compact versions pick a different next token about once in six. DeepSeek's perplexity rises more: going from 4
to 1.6 bits per expert costs it relatively more certainty. That is the price of fitting in 128 GB. (The publisher of
the compact DeepSeek file reports 87.5% agreement with the original model on its own held-out text; this is measured
against Q4 on a different text, so the numbers are not directly comparable.)

## 3. Two Macs as one big memory

llama.cpp can split a model across machines with its RPC backend: the second Mac runs `ggml-rpc-server` with Metal, and
the first Mac sends it its share of the layers (`--rpc host:port`, with `--tensor-split` to balance them).

- Per token only the hidden state of the boundary layer travels between the Macs, a few tens of KB. So the speed stays
  close to a single Mac's (plus a round trip per token), while the memory doubles.
- **Connection:** a Thunderbolt cable between the two MacBooks gives a Thunderbolt Bridge (IP over Thunderbolt). The
  M3 Max has Thunderbolt 4 (40 Gb/s).
- **RDMA over Thunderbolt** (much lower latency, supported by llama.cpp since macOS 26.2) needs **Thunderbolt 5**. The
  M3 Max only has Thunderbolt 4: on this Mac `rdma_ctl` reports "disabled" and `ibv_devices` lists no devices. Apple's
  [TN3205](https://developer.apple.com/documentation/technotes/tn3205-low-latency-communication-with-rdma-over-thunderbolt)
  and [exo](https://github.com/hmbown/exo) list only Thunderbolt 5 Macs (M4 Pro/Max, M3 Ultra and later). With two M3 Max
  MacBooks, the cluster works over plain TCP on the Thunderbolt Bridge.
- With 2 × 128 GB, GLM-5.3-Flash Q4 (200 GB) fits entirely in memory, and DeepSeek-V4.1-Flash Q4 (~298 GB without
  Engram) almost does. That is the realistic way to run the Q4 versions at a useful speed.
- **Built and tested** (MacDeepSeek 1.3): a helper on the same Mac (127.0.0.1), found with Bonjour, holding half of
  GLM-5.3-Flash Compact: writing 20.4 → 19.0 tok/s (−7%), prompt reading unchanged (~180 tok/s), loading 3 minutes
  (55 GB sent to the helper once; with `-c` the helper keeps its part on disk for the next start). Over a real cable add
  the round trip per token (well under a millisecond on Thunderbolt).
- llama.cpp calls its RPC backend a proof of concept ("fragile and insecure"): only use it on a direct cable or a
  trusted network.

## 4. Keep the Mac awake

Overnight measurements showed stalls of exactly 15–16 minutes: the Mac went into idle sleep (10 minutes without user
activity) and only woke for a few seconds every quarter of an hour (DarkWake). A running engine does not keep macOS
awake by itself. MacDeepSeek now holds a "prevent idle system sleep" assertion while the engine runs; the display may
still sleep.

## 5. Engine tuning

- `--ubatch-size 1024` reads prompts ~20% faster than 512 on these MoE models; 2048 grows the compute buffers past the
  wired limit and writing drops from 20 to 3 tok/s.
- Moving 2 extra layers of experts to the CPU (DeepSeek Compact) costs ~10%.
