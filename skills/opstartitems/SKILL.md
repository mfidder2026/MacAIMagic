---
name: opstartitems
description: Programs that start at login and background services (login items, launch agents, launchctl)
platform: macos
---
Tested on macOS 27.

Read: `launchctl list` (your user's services; the first column is the PID, "-" means not running),
`ls ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons`,
`id -u` (your user id, needed below: system_read does not allow `$(…)`, so fill the number in yourself).
Login items: `sfltool dumpbtm` lists everything that starts at login (long), or list the folders above.

| What | check | apply | undo | admin |
|---|---|---|---|---|
| Stop a user agent from starting | `launchctl print gui/<uid>/<label>` | `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<label>.plist` | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label>.plist` | no |
| Remove a login item | `osascript -e 'tell application "System Events" to get the name of every login item'` | `osascript -e 'tell application "System Events" to delete login item "<name>"'` | `osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/<App>.app", hidden:false}'` | no |
| System daemon | `launchctl print system/<label>` | `launchctl bootout system /Library/LaunchDaemons/<label>.plist` | `launchctl bootstrap system /Library/LaunchDaemons/<label>.plist` | yes |

Never touch services whose label starts with `com.apple.`: macOS needs them. Moving a plist away is not needed;
bootout is enough and easy to undo. In System Settings: `open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"`.
