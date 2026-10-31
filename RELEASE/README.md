# MacDeepSeek 1.0 (macOS, Apple Silicon)

`MacDeepSeek-1.0-macOS-arm64.zip` contains the app with the engine built in (llama.cpp with Metal and the
MacDeepSeek patch). The model is **not** included: see [Installation](../README.md#installation) for how to download it.

1. Unzip and move `MacDeepSeek.app` to `/Applications`.
2. The build is ad-hoc signed, not notarized. Right-click → **Open** the first time, or run
   `xattr -dr com.apple.quarantine /Applications/MacDeepSeek.app`.
3. Open **Engine & model**, download the model or choose the folder that holds it, then press **Start engine**.

Check the download: `shasum -a 256 -c MacDeepSeek-1.0-macOS-arm64.zip.sha256`

Requires an Apple Silicon Mac with 128 GB of unified memory and macOS 14 or later.
