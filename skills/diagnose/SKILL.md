---
name: diagnose
description: Finding out what is wrong (slow Mac, hot or loud, battery drains fast, full disk, crashes, network trouble) with reading only
platform: macos
---
Tested on macOS 27. Diagnosis only reads: use system_read, never system_change. Work in steps and say what each result
means in plain words. End with one or two concrete suggestions, and offer to carry them out (that becomes a plan).

| Complaint | Read |
|---|---|
| Slow, hot, loud | `top -l 1 -o cpu -n 15` (busiest processes), `vm_stat` and `sysctl vm.swapusage` (memory pressure, swap), `pmset -g therm`, `uptime` |
| Battery drains | `pmset -g batt`, `pmset -g assertions` (what keeps it awake), `top -l 1 -o power -n 10`, `system_profiler SPPowerDataType` |
| Disk full | `df -h /`, `du -sh ~/Library/Caches ~/Downloads ~/Movies`, `tmutil listlocalsnapshots /` (see the skill opslag) |
| App crashes | `ls -t ~/Library/Logs/DiagnosticReports`, then `cat` of the newest one (read the first 60 lines) |
| Network | `networksetup -getinfo "Wi-Fi"`, `scutil --dns`, `ping -c 3 1.1.1.1`, `ping -c 3 apple.com` |
| General | `sw_vers`, `system_profiler SPHardwareDataType`, `log show --last 10m --predicate 'messageType == error' --style compact` (long: it is cut) |

A number alone helps nobody: compare it with what is normal (memory pressure, swap above a few GB, a process above 100%
CPU for minutes, maximum battery capacity below 80%).
