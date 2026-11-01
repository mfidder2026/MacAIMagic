# MacDeepSeek 1.4 (macOS, Apple Silicon)

`MacDeepSeek-1.4-macOS-arm64.zip` contains the app with the engine built in (llama.cpp with Metal and the
MacDeepSeek patches). The models are **not** included: see [Installation](../README.md#installation) for how to download them.

1. Unzip and move `MacDeepSeek.app` to `/Applications`.
2. The build is ad-hoc signed, not notarized. Right-click → **Open** the first time, or run
   `xattr -dr com.apple.quarantine /Applications/MacDeepSeek.app`.
3. Open **Modellen**, download a model (or choose the folder that holds your models under Modelmap → **Kies map…**), then press **Start**.

Check the download: `shasum -a 256 -c MacDeepSeek-1.4-macOS-arm64.zip.sha256`

Runs on every Apple Silicon Mac (M1 and later) with macOS 14 or later. As the main Mac it needs 128 GB for the models in this app; as a cluster helper any amount of memory helps.

New in 1.4: the Q4 models, larger than memory, are 2.5–3× faster at writing and 7–13× at reading prompts.
DeepSeek-V4.1-Flash Q4 writes at 7–8.5 tok/s instead of 2.8 and reads prompts at 65–95 tok/s instead of 9;
GLM-5.3-Flash Q4 writes at 5–6 tok/s instead of 2.2 and reads prompts at 70–100 tok/s instead of 8. The GPU keeps the
experts a conversation uses most (~95 GB) and reads the others from the SSD with many parallel reads (6 GB/s instead of
1 GB/s); it guesses the next layer's experts and reads them ahead. The cache is saved when the engine stops, so after a
restart the first answer is as fast as the later ones. In a cluster the helpers take whole layers and the main Mac keeps
the rest with the same expert cache; helpers can raise their GPU limit to take more. To make room for the cache, raise
the GPU limit with the button under Modellen.

New in 1.3: Cluster — link several Macs with Thunderbolt and use their memory together (helper Macs lend their GPU, found automatically with Bonjour). Install this same app on every Mac.

New in 1.2.3: DeepSeek-V4.1-Flash Q4 writes correctly (its Engram table is now downloaded in Q6_K; the published MXFP8 table is misread by standard llama.cpp) and runs at ~2.8 tok/s.

New in 1.2.2: the app is quiet when idle (from ~60% CPU to under 1%): animations only run while the model works, and the metrics are sampled less often when the engine is off.

New in 1.2.1: a mini live dashboard at the bottom of the sidebar (speed gauge and sparklines for GPU, CPU, memory and SSD), and a still background (the moving one can be switched on in the settings).

New in 1.2: Qwen3.8-Flash-Next as a fifth model; faster writing with multi-token prediction (GLM and Qwen); the model can
work in a folder per chat (read, write and edit files, run scripts and commands, read logs, with your approval); the Mac
stays awake while the engine runs; the Q4 models load and run (slowly) on a 128 GB Mac.

New in 1.1: four models (DeepSeek-V4.1-Flash and GLM-5.3-Flash, each Compact and Q4), a live dashboard with real-time charts, a side-by-side comparison, and a new look.
