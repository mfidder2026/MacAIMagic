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

## 6. Writing a C64 program: two models, and a limit on thinking

A practical coding test (November 2026, MacAIMagic 1.6): the model writes a Commodore 64 BASIC V2 program, VICE runs
it, and what the screen shows (read with OCR, plus a pixel check for the sprite) goes back to the model, up to four
rounds. Two tasks: a number-guessing game, and a demo with a title and a self-made smiley sprite that moves back and
forth. GLM-5.3-Flash Compact (with MTP) against Qwen3.6-35B-A3B Q4, and Qwen writing a fast draft that GLM reviews.

| | Guessing game | Sprite demo |
|---|---|---|
| GLM alone, no thinking limit | works, 1st try, 210 s | **never wrote code**: 5 × 32,000 tokens of thinking |
| GLM alone, thinking limit 16,000 | | works, 2nd try, 1,413 s |
| Qwen alone, no limit | works, 1st try, 41 s | fails after 4 tries, 1,175 s |
| Qwen alone, thinking limit 16,000 | | fails after 4 tries, 755 s |
| Qwen draft + GLM review (limit 16,000 for the sprite) | works, 1st try, 72 + 859 s | works, 1st try, 155 + 694 s |

- Without a limit GLM kept doubting about hardware details (which sprite Y position is the middle of the screen,
  what each register bit means) and never got to the program. A limit on thinking
  (`thinking_budget_tokens`, with a message that closes the thinking) solved that; since 1.6.1 the app sends it,
  16,000 tokens by default.
- Qwen is 5–10× faster per answer but gets the sprite hardware wrong (it switches the character set with
  `POKE 53272`, or pokes sprite data into screen memory); GLM gets it right. A Qwen draft reviewed by GLM was the
  fastest working sprite program.
- Checking only for an error message is not enough: two "working" results in a first version of the test were an empty
  answer and a screen full of garbage. The test now requires the title on screen and, for the sprite, pixels in the
  middle of the screen.

## 7. Models larger than memory on a Mac with 32 GB

Running a model that does not fit is the point of this app, also on a small Mac. Up to 1.7.1 the plan kept the reserves
measured on 128 GB (8 + 18 GB), which on 32 GB left no expert cache, so a large model fell back to page faults. The
staging reserve now scales with memory (13%, at least 4.5 GB), and below 64 GB a model that streams runs with a 32K
context and no vision, to leave its room to the cache.

Measured on the M3 Max with 103 GB of memory held wired by a small program, so that 32 GB is left for macOS, the page
cache and the model, with 8 threads and the cache the plan gives. `tools/stream_bench.py`: three stories of 60 tokens
starting from a cold cache, then a prompt of ~1,900 tokens.

| Model | Expert cache | Writing (story 1 / 2 / 3) | Prompt reading | SSD per token |
|---|---|---|---|---|
| Qwen3.8-Flash-Next Q4 | 11.1 GB | 1.9 / 4.8 / 5.8 tok/s | 136 tok/s | 0.4–0.5 GB |
| DeepSeek-V4.1-Flash Compact | 8.2 GB | 5.1 / 5.2 / 4.9 tok/s | 42 tok/s | 0.6 GB |
| GLM-5.3-Flash Compact | 9.5 GB | 2.6 / 2.8 / 2.5 tok/s | 18 tok/s | 1.2–1.4 GB |
| DeepSeek-V4.1-Flash Q4 | 5.4 GB | 1.6 / 1.5 / 1.6 tok/s | 47 tok/s | 2.5 GB |
| GLM-5.3-Flash Q4 | 5.5 GB | ~0.1 tok/s (47 tokens in 8 minutes, stopped there) | not reached | |

macOS swapped 1–2 GB during these runs without the speed falling over the rounds. This is an estimate for a real 32 GB
Mac: the M3 Max computes faster than an M1, and its SSD differs. For comparison, Qwen3.6-35B-A3B, which fits whole, writes
at 52 tok/s here with the 32 GB settings and at 43–45 tok/s on a Mac Studio M1 with 32 GB.

## 8. A small model and images (MacAIMagic 1.9.7)

Both came from the Windows version, which measured them first; these numbers are measured here, on the M3 Max.

**Ministral-3-8B Q4** (5.2 GB, no experts): with the app's own measurement, writing 50.6 tok/s, reading a 4,500-token
prompt 629 tok/s, loading 6 s. A model without experts gets no expert cache; on a Mac where it does not fit under the GPU
limit, the layers that do not fit run on the processor, and the context is at least 8K (its KV cache costs 142 KB per
token). Not measured on a Mac with 8 or 16 GB.

**FLUX.2 Klein 4B** with the image engine built for Metal, 4 steps, the whole run with loading:

| Image | GPU | Extra memory | Processor (12 threads) |
|---|---|---|---|
| 512 × 512 | 16–20 s | 3.9 GB with a budget of 1.2 GiB | 78 s |
| 768 × 768 | 34 s | 3.8 GB with 1.2 GiB | |
| 1024 × 1024 | 60 s | 6.8 GB without a limit, 4.1 GB with 5.2 GiB; fails cleanly with 1.2 GiB | |

The app gives the image engine what the GPU may use minus macOS's room: on a Mac with 8 GB that is the budget of 1.2 GiB,
with 768 × 768 as the largest size on the GPU and 1024 on the processor. A Dutch description ("een rode vos die de krant
leest op een bankje in Amsterdam") drew a man reading the paper; the same in English drew the fox. The text model reads
English best, so the page says so.

**Working in parts costs a third on a Mac** (1.9.8). The Windows version always lets the last stage work in parts, because
on a card that costs next to nothing. Measured here at 4 steps:

| Image | Whole | In parts |
|---|---|---|
| 512 × 512 | 14 s, 7.3 GB extra | 16 s, 6.0 GB |
| 1024 × 1024 | 42 s (last stage 9 s), 12.6 GB | 61 s (last stage 26 s), 7.0 GB |

So the app works in parts only where a whole image would not leave the GPU 2 GB beside it: on a Mac with 16 GB at
1024 × 1024, on 8 GB always. Through Compare, which measures the same image on every Mac (a lighthouse, seed 7,
1024 × 1024, with loading): 46 s and 450 image tokens per second. An image token is a patch of 16 × 16 pixels, and the
model works on all of them in every step (4,096 per step at 1024 × 1024); the speed gauge shows them while it draws.

**A better description, with the web** (1.9.8). FLUX draws what it reads, and reads English best. With the switch on,
the chat model rewrites the description in English first and may search the web for what something looks like. Measured
with Ministral-3-8B and "het Rijksmuseum in Amsterdam bij avondlicht, foto": the first instruction let it search, but it
wrote from memory a neoclassical building with a dome, and FLUX drew that. Told that the pages go first and what it
remembers may be wrong, it fetched the museum's own page about the building and wrote a red-brick building with towers
and a passage through the middle: 21 s for the description, 13 s for the image, and the image shows the Rijksmuseum.

**The Eiffel Tower, and what the description must not do** (1.9.11). Asked for "maak een foto van de eifeltoren", Ministral
wrote a long Dutch description full of facts (324 metres, rivets, painted panels, "an upholstered roof"), and FLUX drew a
tower that does not exist. With the same seed, "A photograph of the Eiffel Tower in Paris" drew the real one: the image
model knows famous things by their English name, reads English best, and draws every word, wrong ones too. So the
description is now English (checked, and asked for again when it is not), starts with the subject's English name, holds
only what can be seen, and at most 60 words. A named real thing is looked up first: when the model searches but reads no
page, the app reads the first page with text and an encyclopedia (no stock-photo sites) and has it rewrite from those.
Result: the Eiffel Tower came out right in every run; the Rijksmuseum comes out as a neo-Gothic building with towers,
close but not the real one, because the image model does not know it by name and the small model picks little of its
look from the pages.

## 9. The KV cache in 8 bits: not on the Mac (2026-11-06)

WinAIMagic keeps the KV cache of its second engine in 8 bits (q8_0) on a video card: there it frees VRAM for more layers
(an 8 GB card: 20 instead of 14 tok/s for Ministral) at a quality cost of a KL divergence of 0.0008. Measured here with
llama-bench on the M3 Max, flash attention on, 2,048-token prompts and 128 written tokens, two runs each:

| Model | KV cache | Prompt | Writing | Prompt after 16K | Writing after 16K |
|---|---|---|---|---|---|
| Ministral-3-8B Q4 | 16 bit | 695 tok/s | 51.5 tok/s | 300 tok/s | 31.4 tok/s |
| | 8 bit | 634 tok/s | 42.9 tok/s | 316 tok/s | 34.1 tok/s |
| Qwen3.6-35B-A3B Q4 | 16 bit | 1,383 tok/s | 72.6 tok/s | 789 tok/s | 55.3 tok/s |
| | 8 bit | 1,351 tok/s | 66.3 tok/s | 724 tok/s | 49.5 tok/s |

Mixing the two (keys in 8 bits, values in 16, or the other way round) is 5-40 times slower. On a Mac the GPU reads the
cache from the same memory as everything else, so 8 bits only saves memory, and costs 9-17% of the writing speed at the
contexts the app uses; the gain after 16K for Ministral is within the noise. The app keeps the cache in 16 bits. It could
pay on a Mac with 8 or 16 GB, where the context is short for lack of memory; that has not been measured.


## 10. A conversation's place in the engine, kept across a switch and a restart (2026-11-09)

The engine runs with one slot (`--parallel 1`). What it read of a conversation (its KV cache) was lost when another
conversation, a task, the heartbeat or Documents used the model, and when the engine stopped. llama.cpp's own prompt
cache in RAM (`--cache-ram`, 8 GB by default) helps between conversations, but one DeepSeek-V4.1-Flash state is 5.3 GB
(engine.log: "removing oldest entry (size = 5321.999 MiB)"), so a second conversation pushes the first out, and nothing
survives a restart. The idea came from colibri (github.com/JustVugg/colibri), which keeps a conversation's state
across restarts and "parks" it during an agent's side requests.

llama-server can write a slot to a file and read it back (`--slot-save-path`, `POST /slots/0?action=save|restore`).
The app now does so (`SlotKeeper`): the conversation that had the engine is saved when another one gets it, or before
the engine stops (also when the app quits); a conversation that comes back is restored first. The file name holds the
model, the context size, vision and the draft head, so a state never goes into an engine set up differently.

Measured:

| | |
|---|---|
| Ling-3.0-tiny on the CPU, a 6,820-token prompt | read in 23 s; saved in 0.05 s (122 MB); restored in 0.02 s, also in an engine started anew; the next turn read 36 tokens |
| Ministral-3-8B with its vision projector | saves (544 tokens, 76 MB): vision does not stop it |
| Qwen3.8-Flash-Next Q4 in the app (vision and MTP on), a conversation of 18,000 tokens | stopping the model saved 1.2 GB, including 5 context checkpoints (563 MB) and the MTP draft state (44 MB); after starting it again the next question read 81 tokens in 0.64 s instead of the whole conversation (~45 s at ~400 tokens/s) |

| DeepSeek-V4.1-Flash Compact with the app's arguments (64K context, vision, all in memory), a conversation of 19,913 tokens (the C64 skill and a game) | the first turn read it in 145.1 s (137 tokens/s); saved in 0.03 s (81 MB: its compressed attention keeps ~4 KB per token); the engine stopped and started again (6 s, files in the page cache); restored in 0.05 s; the next question read 20 tokens (0.43 s) and answered in 1.4 s instead of reading the conversation again for 145 s |

DeepSeek's state is small on disk, so the 5.3 GB entries in llama.cpp's RAM cache seen before must hold more than the
conversation's own cells (not looked into). Not measured: GLM-5.3-Flash, and a cluster, where the app does not use it.

## 11. Guessing ahead: MTP, ngram-mod and DFlash on Qwen3.8-Flash-Next (2026-11-10)

From a survey of GitHub projects (AirLLM, streamlx, inferssd, the MLX DFlash ports): the pinned engine (`ddf48f8`) already
has more ways to guess tokens ahead than MTP: `ngram-mod` (it looks the last 24 tokens up in what was already in the
context and proposes the next stretch of up to 64 tokens) and `draft-dflash` (a small drafter writes a block of tokens in
one pass). `tools/spec_bench.py` starts the engine with the app's arguments per setting and writes five texts at
temperature 0. Measured on the M3 Max 128 GB, Qwen3.8-Flash-Next Q4 with vision, tokens per second; where two numbers
are given, two runs (they differ by 5-8%):

| Setting | Story | Writing code | Changing code | Explanation (Dutch) | Thinking (a sum) |
|---|---|---|---|---|---|
| No guessing | 31.4 / 33.4 | 31.3 / 33.1 | 30.7 / 32.5 | 30.7 / 31.1 | 31.3 / 32.5 |
| MTP, 2 ahead (MacAIMagic up to 1.14.10) | 35.6 / 32.8 | 51.3 / 47.1 | 53.0 / 52.2 | 39.3 / 38.8 | 46.1 / 44.2 |
| MTP, 3 ahead | 32.6 | 53.0 | 60.9 | 36.1 | 46.5 |
| **MTP, 2 ahead, with ngram-mod** | 33.1 / 34.2 | 43.3 / 47.8 | **114.9 / 122.0** | 36.6 / 38.0 | 41.1 / 44.5 |
| MTP, 3 ahead, with ngram-mod | 32.7 | 54.1 | 123.2 | 35.5 | 45.8 |
| DFlash2 drafter (incoai, Q4_K_M, 0.36 GB), 4 ahead | 22.0 | 43.4 | 68.4 | 20.8 | 39.0 |
| DFlash2 drafter, 8 ahead | 17.6 | 36.0 | 84.4 | 16.7 | 36.3 |

- **ngram-mod** only proposes when the model writes again what the conversation already holds (here: giving back 40
  lines of Swift with one change). Elsewhere it proposed nothing: the counts of guessed and accepted tokens were exactly
  those of MTP alone, and the speed differences are within the run-to-run spread. MacAIMagic now uses
  `--spec-type draft-mtp,ngram-mod` for the models with an MTP head that fit in memory.
- **DFlash** runs (its model card says llama.cpp cannot drive it for this model yet; llama.cpp #30927, in the pin, fixed
  that), but the big model accepted only ~10% of its guesses on Dutch prose (110 of 1,150 in the story), so it made
  stories and explanations 30-45% slower. Only on changing code did it win, and there ngram-mod wins more. Not used.
- **The text** was the same as without guessing in every setting, except one near-tie word in the thinking task (the
  same place for every setting that checks several tokens at once: rounding in the batched check).
- Not measured: ngram-mod for Ling-3.0-tiny or Qwen3.6 (no MTP head), and for models larger than memory (each checked
  token can need other experts from the SSD), so those get no guessing, as before.

## 12. Kept conversations and context checkpoints (2026-11-10)

A hybrid model (Qwen3.8-Flash-Next, Qwen3.6) keeps a recurrent state next to its KV cache. To go back in a
conversation llama.cpp stores context checkpoints of that state, a few per turn, and a saved conversation
(`/slots/0?action=save`, section 10) carries all of them. The engine's default keeps 32. WinAIMagic found this with
Qwen3.6 on the PC (2 GB per conversation, 6 s per save) and keeps 4; measured here before taking it over.

Qwen3.8-Flash-Next Q4 on the M3 Max with the app's arguments (MTP + ngram-mod, vision, 64K context), a first message
of 12,230 tokens and five short follow-ups, the slot saved after every answer (scratchpad `slot_bench.py`):

| Turn | default (32): file / save | `--ctx-checkpoints 4`: file / save |
|---|---|---|
| 1 | 731 MB / 0.13 s | 731 MB / 0.09 s |
| 2 | 1,070 MB / 0.21 s | 958 MB / 0.15 s |
| 4 | 1,750 MB / 0.28 s | 962 MB / 0.14 s |
| 6 | 2,429 MB / 0.40 s | 966 MB / 0.15 s |
| restore | 0.45 s, then read 23 tokens | 0.16 s, then read 23 tokens |

Each turn added 3 checkpoints of ~112 MB. On this SSD the save stays short either way, but the space grows without
limit up to 32 checkpoints (~3.6 GB a conversation) and fills the 40 GB for kept conversations fast. With 4 the
follow-ups read the same 22-26 tokens, also after a restore. So the app keeps 4 while conversations are kept
(`EngineController.keptCheckpoints`); with the setting off the engine's default stays. Not measured: Qwen3.6 on
the Mac, and a conversation that goes back further than the last checkpoints (an edited earlier message). The app
itself did that with old pictures until 1.14.12: section 13.

## 13. Pictures the model looked at, and a conversation read again from the start (2026-11-11)

Up to 1.14.12 only the last 3 pictures the model looked at (`view_image`) went to the engine as pictures; an older one
became a line of text. So each new look changed the conversation far back, where the oldest of the three stood. A hybrid
model cannot go back there without a context checkpoint before that place, and with `--ctx-checkpoints 4` (section 12)
all checkpoints were near the end: the engine read the whole conversation again.

Seen in `engine.log` of one C64 run with Qwen3.6-35B-A3B heretic Q4 (vision, 262K context) on the M3 Max. The places
where the conversation changed (`f_keep` x the cached tokens) are where an old screenshot stood (the image chunks of the
log, at 58.9K, 59.6K, 80.4K):

| When (engine time) | Changed at | Read again | Time |
|---|---|---|---|
| 7:32 | ~58.7K | 24,709 tokens (from a checkpoint) | 87 s |
| 10:41 | ~58.8K | 82,169 tokens (all) | 195 s |
| 30:39 | ~59.6K | 109,644 tokens (all) | 326 s |
| 59:20 | ~80.3K | 143,729 tokens (all) | 673 s |
| 74:14 | ~81.4K | 148,690 tokens (all) | 676 s |

Reading slows down as the conversation grows: 1,500 tokens/s at the start, 213 tokens/s on average over 144K. A step
that only adds to the conversation read 455-580 new tokens in 2.8-3.7 s at 142K in the same run; a look at a C64
screen (384 x 272, sent at 768 x 544) is about 400 image tokens.

Since then every picture stays a picture for the rest of the conversation; a full context is summarized (`compactAt`),
which leaves the old pictures out. A conversation saved by an older version keeps its older looks as text
(`Conversation.keepLooksAsSent`), so its saved engine state still fits. Not measured yet: a new look with the new
version in a real run.

## 14. llamAmpere's 110+ tok/s next to this Mac (2026-11-11)

[llamAmpere](https://github.com/JakeATX/llamAmpere) (MIT, a llama.cpp fork) reports 110-125 tok/s writing for
Qwen3.8-Flash-Next with a 100K-token prompt at temperature 1.0. That is on an NVIDIA RTX 3090 / 3090 Ti (936 GB/s;
the M3 Max has 400 GB/s), with experts split between the card and RAM. It uses its own pieces:
- a 3-bit model file in its own AI3 format with its own CUDA kernels (80 GB);
- its own 2-bit MTP drafter (Q2S-B);
- a 2-3 bit KV cache (SJ-KVaRN, TurboQuant types);
- "mb-MTP": a guessed token is kept when the model rates it at least as likely as its own pick, so it is lossy and
  only matters above temperature 0;
- adaptive draft depth;
- a 64K draft vocabulary shortlist.

Everything except mb-MTP, adaptive depth and the shortlist is CUDA (sm86) only.

Measured here with the app's engine settings (MTP 2 ahead + ngram-mod, vision, 262K context, 16-bit KV cache):
Qwen3.8-Flash-Next Q4, the Swift sources as context, then a request for a new poem at temperature 0.

| Context | Prompt reading | Writing | Guesses accepted |
|---|---|---|---|
| 1K | 470 tok/s | 36.7 tok/s | 84 of 156 |
| 32K | 392 tok/s | 33.4 tok/s | 91 of 178 |
| 100K | 378 tok/s | 28.7 tok/s | 86 of 164 |

**What this shows:**
- **Long context costs little here.** The model's sparse attention (QSA, the indexer is in the pin) reads only part of
  the cache: -22% at 100K. Full attention would read ~24 KB per context token per written token (12 attention layers,
  2 KV heads of 256), which is 3.2 GB at 128K.
- **Changing code is already at their level.** Section 11 measured 115-122 tok/s, because ngram-mod copies what the
  conversation already holds.
- **New text is where the gap is.** A token reads ~3.4 GB of weights (6B active, ~4.5 bits), and 31-33 tok/s without
  guessing is ~110 GB/s, a quarter of the bandwidth. A dense Ministral-8B reaches ~250 GB/s (section 9). For this
  model the time goes to the many small GPU steps per token (48 layers of MoE routing and recurrent GDN state), not
  to reading memory.
- **The MTP drafter's output layer** is 2560 × 248,320 in Q8_0 (0.68 GB), read in full for every guessed token: about
  1.4 GB per step at 2 ahead. llamAmpere's shortlist gave +1.8% on Flash-Next on their card (45.80 to 46.61 tok/s);
  on this Mac the share of that layer is larger. Not measured.

**The candidates, measured** with `tools/spec_bench.py` (the app's arguments, five texts, two rounds each,
alternating):

| Task | Now | Drafter output layer in 4 bits | Engine at upstream `cb44fdb` (2026-11-11) |
|---|---|---|---|
| Story | 35.0 / 34.9 | 37.2 / 37.3 | 35.4 / 35.4 (now: 35.8 / 34.9) |
| Writing code | 49.6 / 49.1 | 49.5 / 51.1 | 49.1 / 48.1 (now: 50.1 / 49.8) |
| Changing code | 120.9 / 118.2 | 114.4 / 118.6 | 118.6 / 121.6 (now: 121.3 / 126.7) |
| Explanation | 36.4 / 38.5 | 37.8 / 34.5 | 37.7 / 38.5 (now: 35.4 / 37.8) |
| Thinking | 43.3 / 44.5 | 43.2 / 45.6 | 43.2 / 44.0 (now: 42.4 / 44.2) |

- **The drafter's output layer in 4 bits** (`llama-quantize --output-tensor-type q4_K`, 644 to 341 MiB): about +1% on
  average. Only the story is faster in both rounds (+6.6%). Same text, same accepted guesses. The drafter is not
  what holds the speed back.
- **The newer engine** (upstream + patch 0001; patch 0002, expert streaming, no longer applies there): +0.9% without
  guessing (31.5 to 31.8 tok/s), -1.2% with the app's setting. Within the spread; same text and accepted guesses.
- **Temperature 1.0** (the app's default), MTP 2 + ngram-mod, seed 42:

  | Task | MTP, temperature 0 | MTP, temperature 1 | No guessing, temperature 1 | Guesses accepted (0 → 1) |
  |---|---|---|---|---|
  | Story | 35.3 | 33.0 | 32.6 | 44% → 38% |
  | Writing code | 50.0 | 45.0 | 32.1 | 84% → 72% |
  | Changing code | 124.0 | 118.5 | 31.4 | 93% → 93% |
  | Explanation | 36.6 | 33.9 | 30.4 | 62% → 52% |
  | Thinking | 43.3 | 44.6 | 31.5 | 66% → 68% |

  mb-MTP accepts every guess that is the model's top pick, so at temperature 1 it gets at least the acceptance of
  temperature 0 back: 4-10% here, at the cost of text that leans toward the most likely words.

What is left is the efficiency of this model's GPU work on Metal: 31.5 tok/s without guessing is a quarter of the
bandwidth. Faster would take Metal work for qwen4exp (fusing the MoE routing and the GDN step, as upstream did for
DeepSeek-V4 and GLM in `ea40a3a`) or another engine; MTPLX (MLX) reports 41 tok/s on this model (section 1), not
measured on the same texts.

For WinAIMagic, llamAmpere itself is the thing to try on an RTX 30-series card; its numbers are not measured here.
