# Research notes

Measurements and findings behind MacAIMagic's choices, all on a MacBook Pro M3 Max with 128 GB.

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

With 3 tokens ahead, too many guesses on creative text are rejected and checking them costs more than it saves. MacAIMagic
therefore uses MTP with 2 tokens ahead for the models that have an MTP head.

DeepSeek-V4.1 has no MTP head in these files; its own draft model (DSpark, 8 GB) does not fit next to the 115 GB compact
model.

## 2. Models larger than memory (Q4)

The Q4 versions are close to the original weights, but on a 128 GB Mac part of their experts must come from the SSD.

| Model | Experts | Experts per token |
|---|---|---|
| DeepSeek-V4.1-Flash Q4 | 289 GB (40 layers × 384 experts of 18.8 MB, MXFP4) | 6 per layer: 4.5 GB |
| GLM-5.3-Flash Q4 | 190 GB (43 layers × 288 experts of 15.2 MB, Q4_K/Q5_K) | 8 per layer: 5.2 GB |

### Before: page faults (MacAIMagic 1.3)

The first layers kept their experts on the CPU, mapped from the file; the rest of memory held whole layers on the GPU.

- **Weight repacking must be off.** llama.cpp repacks MXFP4 experts for faster CPU math, into ordinary RAM. For 238 GB
  of CPU experts that never fits: the Mac swaps (150 GB swapped out in our test) and the process is killed. `--no-repack`
  keeps them mapped.
- **Whole-file read-ahead must be off.** At load, llama.cpp asks macOS to read the entire file ahead (`MADV_WILLNEED`).
  For a model larger than memory that reads hundreds of GB and evicts itself. Patch 0001 adds `LLAMA_MMAP_PREFETCH=0`.
- **DeepSeek Q4 wrote nonsense at first.** Its Engram table shard is published as "MXFP8", stored with ggml type id 43.
  Standard llama.cpp uses id 43 for F8_E4M3 (no block scales), so it read the table wrongly: the sizes give it away
  (202.8 GB for 196.6 G values is 33 bytes per 32, the MXFP8 layout). The fix is the same table in Q6_K, which the
  publisher offers as a drop-in shard: `tools/models.json` downloads that one and stamps its header as shard 8 of 9.
- **The result was slow: ~2.8 tok/s for DeepSeek Q4 and ~2.2 tok/s for GLM Q4**, ~9 tok/s prompt reading.

### Why: how fast can the SSD deliver experts?

`page faults` is what llama.cpp did; the rest are alternatives, all reading 18 expert matrices of 6.3 MB (one token,
one layer of DeepSeek) from parts of the file that were not in memory:

| How | GB/s |
|---|---|
| Copy from the mapped file, 1 thread (llama.cpp's MoE cache) | 0.8 |
| Page faults from 12 threads, each on its own rows (llama.cpp's CPU experts) | 1.7 |
| `madvise(MADV_WILLNEED)`, 1 thread | 2.7 |
| `madvise(MADV_WILLNEED)` on 18 threads, one matrix each | **6.5** |
| `pread`, 6 to 18 threads | **6.6** |

macOS serves a page fault on a mapped file with a small read (16–22 KB on average here), one after another. A
`madvise(WILLNEED)` on a whole range becomes one large request, and many of those at once keep the SSD busy. Split into
1 MiB chunks over 16 threads, even 3 missing matrices (19 MB) arrive at 6 GB/s. On data already in memory the
`madvise` costs 16 µs per matrix.

### Now: the GPU expert cache, filled at SSD speed (MacAIMagic 1.4)

llama.cpp has a GPU cache for experts kept on the host (`--moe-cache-mib`, a segmented LRU per group of layers): the
router picks the experts, the cache uploads the ones it does not have, and the GPU computes all of them. Out of the box it
made GLM Q4 slower (1.4–1.6 tok/s), because it read every missing expert with page faults on one thread. Patch 0002:

1. **Parallel loading.** A pool of 16 threads reads the missing experts in 1 MiB chunks, each with one `madvise`
   request, and writes them straight into the cache: on unified memory the cache is ordinary memory, and the GPU is idle
   at that moment anyway (it just picked the experts).
2. **Prompt reading** copies the experts a large batch needs the same way, and reads the next layer's experts while the
   GPU computes the current one. Batches of up to 8 tokens read from the cache; larger ones copy what they use, without
   pushing the conversation's experts out of the cache.
3. **Read-ahead.** Applying the router of the next layer to the input of the current layer guesses the next layer's
   experts well: 76% of the misses are among its 12 best guesses. Reading all of them costs too much (5.5 reads per
   miss, slower overall); reading the 2 best guesses that are not cached covers 48% of the misses and is ~5% faster.
4. **Warm start.** The cache contents are saved when the engine stops and uploaded again (in parallel) at the next start.

All experts stay mapped from the file; with the GPU limit raised to 120 GB the cache gets ~100 GB of the GPU, and macOS
keeps ~16 GB for itself and as a staging area for experts on their way from the SSD.

Measured with `tools/stream_bench.py`: three stories of 200 tokens (temperature 0, so every run writes the same text; the
cache warms up over the rounds), then a prompt of ~1,850 tokens. Cache sizes as `--moe-cache-mib`; averages of 2–3 runs.

**DeepSeek-V4.1-Flash Q4**

| | Writing (story 1 / 2 / 3) | Prompt reading |
|---|---|---|
| 1.3: page faults | 2.6–2.9 tok/s | 9 tok/s |
| cache 90 GB, parallel loading | 6.1 / 8.1 / 7.5 tok/s | 48 tok/s |
| + read-ahead (2 per layer) | 6.2 / 8.2 / 7.6 tok/s | 47 tok/s |
| + prompt batch 2048 (cache 86 GB) | 6.1–6.3 / 8.2–8.4 tok/s | 65 tok/s |
| + prompt read-ahead (MacAIMagic 1.4) | 6.4 / 8.3 tok/s | **66 tok/s** |
| + warm start (cache saved by the previous run) | **8.0** / 8.3 / 7.8 tok/s | 47 tok/s |

**GLM-5.3-Flash Q4**

| | Writing (story 1 / 2 / 3) | Prompt reading |
|---|---|---|
| 1.3: page faults | 2.2 tok/s | 8 tok/s |
| llama.cpp's MoE cache as is | 1.4–1.6 tok/s | a 30-token prompt took 15–70 s |
| cache 90 GB, parallel loading, read-ahead | 5.2 / 5.9 / 5.3 tok/s | 39 tok/s |
| + prompt batch 2048 (cache 86 GB) | 5.2 / 6.2 tok/s | 61 tok/s |
| + prompt read-ahead (MacAIMagic 1.4) | 5.1 / 6.1 tok/s | **72 tok/s** |

And measured by the app itself (`MACAIMAGIC_BENCH`: the app's own memory plan, ~94 GB of cache, ubatch 4096; a
2,500-token prompt, then 300 tokens of a story), first with an empty cache, then with the cache the first run saved:

| | Writing, cold / warm | Prompt reading, cold / warm | Wired |
|---|---|---|---|
| DeepSeek-V4.1-Flash Q4 | 7.1 / **8.3** tok/s | 67 / **93** tok/s | 113–114 GB |
| GLM-5.3-Flash Q4 | 5.2 / **5.4** tok/s | 71 / **102** tok/s | 109–111 GB |

A warm cache also speeds up prompt reading: the experts it holds are copied within the GPU instead of read from the SSD.
Loading takes 12–13 s cold and 28–30 s warm (16 s to upload ~90 GB of cached experts at 6 GB/s).

The cache hits 91.6% (DeepSeek) and 89.8% (GLM) of the experts a token needs; a warm start raises DeepSeek to 93.2%.
A token of DeepSeek Q4 takes ~50 ms of GPU work (the same as the compact model: 5,400 graph nodes, 42 graph splits) plus
~40–70 ms of waiting for missing experts. GLM uses 8 of its 288 experts per layer (DeepSeek 6 of 384), so the same cache
misses more often.

What did not work, or not well enough:

- **A larger cache.** 96.6 GB of cache (115 GB wired in all) ran steadily. 105 GB (123 GB wired) left too little for macOS:
  it swapped 12 million pages, and writing dropped to 0.2 tok/s. The plan keeps 26 GB for macOS, other apps and the pages
  on their way from the SSD (~95 GB of cache on a 128 GB Mac), and gives up more when other apps hold more than usual.
- **Reading many guesses ahead.** The 12 best guesses cover 76% of the misses, but cost 5.5 reads per miss and made
  writing slower. The 2 best uncached guesses per layer cover 48% and gain ~2%.
- **MTP.** GLM's MTP head checks 3 tokens per pass; for a streamed model that needs more experts per pass: 5.2–5.5 tok/s
  with MTP against 5.2–5.9 without (temperature 0). MacAIMagic turns MTP off for models larger than memory.
- **Engram rows in parallel.** Reading DeepSeek's 48 Engram rows per token on 16 threads instead of one after another
  made no difference (macOS serves these small reads fast), so the engine keeps reading them in order.

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
- **Built and tested** (MacAIMagic 1.3): a helper on the same Mac (127.0.0.1), found with Bonjour, holding half of
  GLM-5.3-Flash Compact: writing 20.4 → 19.0 tok/s (−7%), prompt reading unchanged (~180 tok/s), loading 3 minutes
  (55 GB sent to the helper once; with `-c` the helper keeps its part on disk, in `~/Library/Caches/llama.cpp/rpc`, for
  the next start). Over a real cable add
  the round trip per token (well under a millisecond on Thunderbolt).
- llama.cpp calls its RPC backend a proof of concept ("fragile and insecure"): only use it on a direct cable or a
  trusted network.
- **How 1.4 splits the layers.** llama.cpp puts RPC devices before the local GPU and assigns layers in that order, so the
  helpers get the first layers. The app gives each helper as many whole layers as its GPU holds (`--tensor-split` with
  layer counts: exact, since llama.cpp maps layer *i* to the device whose cumulative share passes *i*/(layers + 1)) and
  keeps the last layers. If those do not fit in the main Mac's memory, their experts stay mapped (`--override-tensor`
  for exactly those layers) and the main Mac's GPU caches the most used ones; the MoE cache only uses the devices that
  have mapped experts, so all of it lands on the main Mac. Tested with a helper on the same Mac taking 3 layers of
  DeepSeek-V4.1-Flash Q4 and the main side streaming the other 37 with the cache: correct answers, loading 74 s.

## 4. Keep the Mac awake

Overnight measurements showed stalls of exactly 15–16 minutes: the Mac went into idle sleep (10 minutes without user
activity) and only woke for a few seconds every quarter of an hour (DarkWake). A running engine does not keep macOS
awake by itself. MacAIMagic now holds a "prevent idle system sleep" assertion while the engine runs; the display may
still sleep.

## 5. Engine tuning

- `--ubatch-size 1024` reads prompts ~20% faster than 512 on these MoE models; 2048 grows the compute buffers past the
  wired limit and writing drops from 20 to 3 tok/s.
- For models larger than memory, every ubatch of a prompt reads all experts that are not cached from the SSD once, so
  the batch size decides how often a prompt reads them. `--ubatch-size 2048` reads a 1,850-token prompt in one pass: 65
  instead of 48 tok/s (DeepSeek Q4), 61 instead of 39 (GLM Q4). `--ubatch-size 4096` does the same for a 2,500-token
  prompt (a system prompt with tools and a question): 81 instead of 60 tok/s (DeepSeek Q4), 92 instead of 56 (GLM Q4).
  The compute buffers grow only a little: DeepSeek Q4 4.8 / 5.2 / 6.2 GB at ubatch 1024 / 2048 / 4096, GLM Q4 2.8 / 3.8
  GB at 2048 / 4096. MacAIMagic uses 4096 for these models.
- While the GPU computes a layer of a prompt, the engine reads the next layer's uncached experts in the order the
  scheduler copies them (up, gate, down), at most 4 GB: GLM Q4 72 instead of 61 tok/s, DeepSeek Q4 66 instead of 65.
  Reading them in a different order, or all of them, made DeepSeek slower (58 tok/s): the pages were pushed out of the
  page cache before they were used.
- Moving 2 extra layers of experts to the CPU (DeepSeek Compact) costs ~10%.
