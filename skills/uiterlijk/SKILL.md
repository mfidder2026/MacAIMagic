---
name: uiterlijk
description: Appearance, Dock, Finder, menu bar, screenshots (dark mode, accent colour, Dock position and size, hidden files, path bar)
platform: macos
---
Tested on macOS 27. Use system_read for the current value and system_change for a change. Every step needs a check,
an apply and an undo. None of these need admin.

A key that was never set gives "Could not find key …": that is the default value. Undo then is `defaults delete …`.
Restart the program that reads the setting in the same apply (`killall Dock`, `killall Finder`, `killall SystemUIServer`).

| What | check | apply (example) | undo (example) |
|---|---|---|---|
| Dark mode | `defaults read -g AppleInterfaceStyle` | `osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'` | the same with `false` |
| Dock position | `defaults read com.apple.dock orientation` | `defaults write com.apple.dock orientation -string left; killall Dock` | `defaults delete com.apple.dock orientation; killall Dock` (or write the old value) |
| Dock auto-hide | `defaults read com.apple.dock autohide` | `defaults write com.apple.dock autohide -bool true; killall Dock` | `defaults delete com.apple.dock autohide; killall Dock` |
| Dock icon size | `defaults read com.apple.dock tilesize` | `defaults write com.apple.dock tilesize -int 48; killall Dock` | old value, or `defaults delete com.apple.dock tilesize; killall Dock` |
| Recent apps in Dock | `defaults read com.apple.dock show-recents` | `defaults write com.apple.dock show-recents -bool false; killall Dock` | `defaults delete com.apple.dock show-recents; killall Dock` |
| Hidden files in Finder | `defaults read com.apple.finder AppleShowAllFiles` | `defaults write com.apple.finder AppleShowAllFiles -bool true; killall Finder` | `defaults delete com.apple.finder AppleShowAllFiles; killall Finder` |
| Path bar in Finder | `defaults read com.apple.finder ShowPathbar` | `defaults write com.apple.finder ShowPathbar -bool true; killall Finder` | `defaults delete com.apple.finder ShowPathbar; killall Finder` |
| File extensions | `defaults read -g AppleShowAllExtensions` | `defaults write -g AppleShowAllExtensions -bool true; killall Finder` | `defaults delete -g AppleShowAllExtensions; killall Finder` |
| Screenshot folder | `defaults read com.apple.screencapture location` | `mkdir -p ~/Pictures/Screenshots; defaults write com.apple.screencapture location ~/Pictures/Screenshots; killall SystemUIServer` | `defaults delete com.apple.screencapture location; killall SystemUIServer` |
| Screenshot format | `defaults read com.apple.screencapture type` | `defaults write com.apple.screencapture type -string jpg; killall SystemUIServer` | `defaults delete com.apple.screencapture type; killall SystemUIServer` |
| Accent colour | `defaults read -g AppleAccentColor` | `defaults write -g AppleAccentColor -int 4` (−1 graphite, 0 red, 1 orange, 2 yellow, 3 green, 4 blue, 5 purple, 6 pink) | `defaults delete -g AppleAccentColor` |

An accent colour shows in apps after they restart; say so. For something not in this table, read the domain first
(`defaults read com.apple.dock`) and never guess a key: say you are not sure, or open the right pane of System Settings
with `open "x-apple.systempreferences:com.apple.Appearance-Settings.extension"` (Desktop & Dock:
`com.apple.Desktop-Settings.extension`).
