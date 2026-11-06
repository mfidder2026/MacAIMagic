---
name: software
description: Installing, updating and removing software (Homebrew apps and tools, macOS updates, App Store apps)
platform: macos
---
Tested on macOS 27 with Homebrew in /opt/homebrew.

Read: `brew --version`, `brew list --versions`, `brew list --cask`, `brew outdated`, `brew info <name>`,
`softwareupdate --list` (macOS updates; slow, up to a minute), `ls /Applications`.

| What | check | apply | undo | admin |
|---|---|---|---|---|
| Install a tool | `brew list --versions <name>` | `brew install <name>` | `brew uninstall <name>` | no |
| Install an app | `brew list --cask --versions <name>` | `brew install --cask <name>` | `brew uninstall --cask <name>` | no (some casks ask for the password themselves: then use admin) |
| Update everything from Homebrew | `brew outdated` | `brew upgrade` | (no exact undo: say so) | no |
| macOS update | `softwareupdate --list` | do not install it yourself: open `x-apple.systempreferences:com.apple.Software-Update-Settings.extension` | — | — |

Find the exact cask or formula name first with `brew search <word>`, then `brew info <name>`. Never install from a URL or script the user did not name, and never
`curl … | sh`. Homebrew itself missing: tell the user to install it from brew.sh themselves.
