---
title: Skills
icon: book.closed
keywords: skills instructions SKILL.md own subject
---
A **skill** is a short guide for the model about one subject, with commands that were tested on this macOS version. The model sees only the names, and loads a skill when it needs it. That keeps the prompt short and the model fast.

## On or off
Skills are on by default. Turn them off under Settings → **System management** → **Skills**.

## Built-in skills
| Skill | About |
|---|---|
| uiterlijk (appearance) | dark mode, accent colour, Dock, Finder, screenshots |
| energie (energy) | sleep, display sleep, Power Nap, battery |
| netwerk (network) | DNS, Wi-Fi, IP address, flushing the DNS cache |
| software | Homebrew, macOS updates |
| opstartitems (startup items) | programs that start at login, background services |
| opslag (storage) | what takes space, cleaning up safely through the trash |
| privacy-beveiliging (security) | firewall, Gatekeeper, FileVault, privacy permissions |
| diagnose | slow, hot, battery drains fast, crashes, network trouble |

## Making your own skill
1. Settings → System management → **Open folder**.
2. Make a folder, for example `my-printer`, with a file `SKILL.md` in it:
```
---
name: my-printer
description: Installing and fixing the office printer
platform: macos
---
Write the steps and commands here.
```
3. Your own skill with the same name as a built-in one replaces the built-in one.
4. A WinAIMagic skill (`platform: windows`) can go into the folder as it is: it loads anyway. The model is told where the skill's files are, and what differs on a Mac (zsh instead of PowerShell, `python3`, `$HOME`).

## Having a skill made
Ask in the chat: *"Make a skill for programming in C64 assembler."* The model writes it, shows it on a card first, and after your approval puts it in the folder of your own skills. It is in the list from then on.
