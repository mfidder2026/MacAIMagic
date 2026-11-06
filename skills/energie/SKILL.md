---
name: energie
description: Energy and sleep (display sleep, computer sleep, Power Nap, low power mode, battery report, what keeps the Mac awake)
platform: macos
---
Tested on macOS 27. Reading needs no admin; every `pmset` change needs admin (set `admin: true`).

Read: `pmset -g` (current settings), `pmset -g custom` (battery and charger apart), `pmset -g batt` (charge),
`pmset -g assertions` (what keeps the Mac awake now), `pmset -g log` is long: prefer `pmset -g stats`.

Change (minutes; 0 = never). `-a` all power sources, `-b` battery, `-c` charger:

| What | check | apply | undo |
|---|---|---|---|
| Display sleep | `pmset -g` (line displaysleep) | `pmset -a displaysleep 30` | `pmset -a displaysleep <old value>` |
| Computer sleep | `pmset -g` (line sleep) | `pmset -c sleep 0` | `pmset -c sleep <old value>` |
| Disk sleep | `pmset -g` (line disksleep) | `pmset -a disksleep 10` | old value |
| Power Nap | `pmset -g` (line powernap) | `pmset -a powernap 0` | `pmset -a powernap <old value>` |
| Low power mode | `pmset -g` (line lowpowermode) | `pmset -b lowpowermode 1` | `pmset -b lowpowermode <old value>` |

Write the old value from the check into undo; never undo to a guess. `hibernatemode` and `standby` can lose work when
the battery runs out: only change them when the user asks for exactly that, and say why it is risky.

Battery health: `system_profiler SPPowerDataType` (cycle count, condition, maximum capacity).
