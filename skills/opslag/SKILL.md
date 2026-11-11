---
name: opslag
description: Disk space (what takes space, large folders, caches, emptying the trash safely, Time Machine snapshots)
platform: macos
---
Tested on macOS 27.

Read: `df -h /`, `du -sh ~/Downloads ~/Library/Caches ~/Movies ~/"Library/Application Support"`,
`du -d 1 -h ~/Library` (one level), `tmutil listlocalsnapshots /`, `mdfind -onlyin ~ "kMDItemFSSize > 2000000000"`
(files over 2 GB), `ls -la ~/.Trash`.

Making room — always as system_change, and always to the trash, never `rm`:

| What | apply | undo |
|---|---|---|
| A file or folder to the trash | `osascript -e 'tell application "Finder" to delete POSIX file "/Users/<you>/Downloads/big.dmg"'` | `mv ~/.Trash/big.dmg ~/Downloads/` |
| Caches of one app | to the trash as above, the folder `~/Library/Caches/<app>` | move it back from the trash |
| Old local snapshots | `tmutil thinlocalsnapshots / 20000000000 4` (admin) | no undo: say so |

Show the user what you want to remove and how large it is before the plan. Emptying the trash removes files for good:
do not do it; tell the user to do it in the Finder when they are sure.
