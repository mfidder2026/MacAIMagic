# MacDeepSeek 1.1 (macOS, Apple Silicon)

`MacDeepSeek-1.1-macOS-arm64.zip` contains the app with the engine built in (llama.cpp with Metal and the
MacDeepSeek patch). The models are **not** included: see [Installation](../README.md#installation) for how to download them.

1. Unzip and move `MacDeepSeek.app` to `/Applications`.
2. The build is ad-hoc signed, not notarized. Right-click → **Open** the first time, or run
   `xattr -dr com.apple.quarantine /Applications/MacDeepSeek.app`.
3. Open **Modellen**, download a model (or choose the folder that holds your models under Modelmap → **Kies map…**), then press **Start**.

Check the download: `shasum -a 256 -c MacDeepSeek-1.1-macOS-arm64.zip.sha256`

Requires an Apple Silicon Mac with 128 GB of unified memory and macOS 14 or later.

New in 1.1: four models (DeepSeek-V4.1-Flash and GLM-5.3-Flash, each Compact and Q4), a live dashboard with real-time charts, a side-by-side comparison, and a new look.
