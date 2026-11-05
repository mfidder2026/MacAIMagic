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

**Last WinAIMagic commit taken over: `2473cd4`** (the first complete Windows version, 0.1.0). Everything after it has not been considered for the Mac yet.

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

**Open from Windows when this file was written,** so the first take-over knows where to look. None of this has been decided for the Mac:

- `ab7c2c5`: the Documents button reads "Document voorbereiden". Here it still reads "Maak een document" (`DocumentsView.swift`). The button on the next screen, "Maak het document", stays.
- `f47ce6d`: the version stands beside the name at the top of the sidebar. Here it only shows in the system check.
- `d97fc36` and `de64e73`: a choice to skip experts on GLM, beside the Start button. It depends on the Windows main engine, so check first whether it means anything here.
- The section "Mac gaps fixed here" in WinAIMagic's [docs/PARITY.md](https://github.com/mfidder2026/WinAIMagic/blob/main/docs/PARITY.md) lists faults Windows fixed that were still in this version at 1.9.5.

## Building and testing

```bash
cd App && swift test
```

`./scripts/make_app.sh` builds `dist/MacAIMagic.app`. The README explains the rest, including the engine tests. New texts need translations in `tools/i18n/{en,de,fr}.json`, and `python3 tools/i18n.py build` writes `Translations.swift` from them. Publish a release only when the owner asks.
