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

**Last WinAIMagic commit taken over: `eac2164`** (2026-11-06: version 0.2.8). Everything after it has not been considered for the Mac yet.

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

**Still open after the take-over of `eac2164`:**

- `d97fc36`, `de64e73` (skipping experts on GLM) do not apply: they need the Windows main engine.
- `3505bb6`: the 8-bit KV cache costs 9-17% of the writing speed here (docs/RESEARCH.md section 9), so the Mac keeps 16 bits. Its "Exporteer meting" and "Deel op GitHub" were added here on the owner's request (`942aead`), with the Mac's own form in `.github/ISSUE_TEMPLATE/meting.yml`.
- Ministral and FLUX were measured on the M3 Max only, not on a Mac with 8 or 16 GB.
- `.github/workflows/check-models.yml` could not be pushed (the token has no `workflow` scope).

## Windows work from the branch `agent-features`

[PARITY.md](PARITY.md) lists what WinAIMagic needs for the experimental skills, system management and the help, with
the Windows counterpart of each piece. Tick an item there when it is done on Windows.

## Building and testing

```bash
cd App && swift test
```

`./scripts/make_app.sh` builds `dist/MacAIMagic.app`. The README explains the rest, including the engine tests. `python3 tools/check_catalog.py` checks the model catalog against the server (headers only); every address in `tools/models.json` names one commit. New texts need translations in `tools/i18n/{en,de,fr}.json`, and `python3 tools/i18n.py build` writes `Translations.swift` from them. Publish a release only when the owner asks.
