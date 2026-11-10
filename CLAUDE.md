# MacAIMagic

There is also a Windows version, [WinAIMagic](https://github.com/mfidder2026/WinAIMagic). The two share no code: this one is Swift, the Windows one is C#. Each is built and tested on its own platform, by a Claude on that machine. What is said in a session on one machine does not reach the other; only what is on GitHub does.

## Keeping the two versions alike

The owner types a change once, on the machine in front of them. On the other machine they only say something like "Neem de nieuwe wijzigingen uit WinAIMagic over". So the commit has to be enough to work from.

### After a change here

Write a commit message that stands on its own:

- what changed for the user, and why;
- what was measured or run, and what was not;
- a last line saying what Windows should do with it, one of:
  - `Windows: take over`
  - `Windows: adapt` and what differs
  - `Windows: not needed` and why, for a change that is Mac-only

Commit on `main` and push: the other machine only sees `main`.

### Taking over from Windows

**Last WinAIMagic commit taken over: `04209a5`** (2026-11-10: WinAIMagic 1.14.11 and the take-over of the Mac's 475ef67; the Mac then took 1.14.12). Everything after it has not been considered for the Mac yet.

1. List what is new. Replace `<commit>` with the marker above:

   ```bash
   gh api repos/mfidder2026/WinAIMagic/compare/<commit>...main --jq '.commits[] | .sha[0:7] + " " + (.commit.message | split("\n")[0])'
   ```

2. Read each commit's diff (`gh api repos/mfidder2026/WinAIMagic/commits/<sha> -H "Accept: application/vnd.github.diff"`) and decide per change: take over, adapt, or does not apply. A commit that says `Takes over MacAIMagic <sha>` came from here and needs nothing.
3. Take care with memory and engine changes. Copying them is usually wrong: the Windows planner was redesigned for VRAM + RAM + SSD, and it has two engines, while a Mac has one pool of memory and one engine.
4. Build and test here. Use the Windows test names where they apply.
5. Never present the Windows numbers as measured here. Write what was measured on this platform, and say so when something is an estimate.
6. Move the marker above to the last commit you considered, also when a change does not apply.
7. Put `Takes over WinAIMagic <sha>` in the commit message. Report to the owner in plain words what was taken over, what was adapted and what does not apply.

**Taken over from `46c0d7a` … `04209a5` (2026-11-10):** only the last context checkpoints while conversations are kept (`46c0d7a`, adapted: `--ctx-checkpoints 4`, measured here with Qwen3.8-Flash-Next, see the commit). Not needed: its tray fix (WinUI), `c80559e` and `04209a5` (they take over the Mac's own commits), `ee69ec2` (version 1.14.11).

**Taken over from `f77a1a4` … `ea715d4` (2026-11-09):** the model dot shows the engine state (`bbbb693`), a skill in the user's folder loads whatever its platform (`563b379`, the other way round: a Windows skill here), the last 4 thinking lines (`d1f9d01`), the load/unload gauge with a remembered clock (`abd8af4`, the Mac's own first guess: 1.5 GB/s of model memory), deleting a Documents project (`b5c78ab`), the working folder's files beside the chat (`18367d9`, polled once a second instead of a watcher). Not needed: `35cde7b` (a WinUI wrap panel), and the version commits `f77a1a4`, `7cd6c64`, `b0b381c`, `ea715d4`. The owner's C64 skill was repaired on the PC (c64build.py, tokenizing like the C64); that lives in the PC's own skills folder and is not on GitHub.

**Taken over from `a320ea0` … `1cf5577` (2026-11-09):** Ling-3.0-tiny as the model for a Mac with 8 GB (`7b921e5`, `5cecf08`; Nanbeige was never released and is not taken), the loop guard and the DRY sampler in Documents (`62b9b0e`), and a Telegram card that no longer drops during a passing network problem (`a320ea0`). Not needed: the Windows speech engine (`a5a23c9`, the Mac has SpeechAnalyzer), packaging (`c0c512f`, `62b9b0e`'s setup), the README (`f2a0a16`), and the commits that take over the Mac's own work (`4c845e6`, `b7517f6`, `00d0211`, `1cf5577`).

**Still open after the take-over of `1cf5577`:**

- Ling-3.0-tiny was measured on the M3 Max only (also with all experts on the processor, as an 8 GB Mac runs it); not on a Mac with 8 or 16 GB.

**Still open from the take-over of `eccb3d8`:**

- `d97fc36`, `de64e73` (skipping experts on GLM) do not apply: they need the Windows main engine.
- `3505bb6`: the 8-bit KV cache costs 9-17% of the writing speed here (docs/RESEARCH.md section 9), so the Mac keeps 16 bits. Its "Exporteer meting" and "Deel op GitHub" were added here on the owner's request (`942aead`), with the Mac's own form in `.github/ISSUE_TEMPLATE/meting.yml`.
- Ministral and FLUX were measured on the M3 Max only, not on a Mac with 8 or 16 GB.
- `.github/workflows/check-models.yml` could not be pushed (the token has no `workflow` scope).
- `8fd8ddf`: UAC, the restore point and the registry export are Windows-only; the Mac has the password dialog of macOS and a local Time Machine snapshot. Its skills and help were taken over before (from here).
- `246584d`: Mac and Windows in one cluster is not tried with real machines (both pin `ddf48f8`).
- `6d69382`, `c769d2d` (0.2.12) take over the Mac's 1.10 and 1.11 and need nothing here. Not run on Windows: a notification and its click, the tray menu by hand, Start with Windows, a task starting on its own, connectors and the heartbeat with a real model.

## Windows work from the branch `agent-features`

[PARITY.md](PARITY.md) lists what WinAIMagic needs for the skills, system management, the help and the connectors (MCP), with
the Windows counterpart of each piece. Tick an item there when it is done on Windows.

## Building and testing

```bash
cd App && swift test
```

`./scripts/make_app.sh` builds `dist/MacAIMagic.app`. The README explains the rest, including the engine tests. `python3 tools/check_catalog.py` checks the model catalog against the server (headers only); every address in `tools/models.json` names one commit. New texts need translations in `tools/i18n/{en,de,fr}.json`, and `python3 tools/i18n.py build` writes `Translations.swift` from them. Publish a release only when the owner asks.

**Version:** `CFBundleShortVersionString` in `scripts/make_app.sh`. WinAIMagic and MacAIMagic carry the same version number (since 1.11.0, on the owner's request). A new version on either side takes the next number after the highest of the two (check the other repository's `main` first), and when one side takes the other's work over, it takes that side's number. A number may be skipped on one side; it never goes below the other side. Windows keeps its number in `Directory.Build.props`.
