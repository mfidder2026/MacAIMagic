---
title: Working in a folder
icon: folder.badge.gearshape
keywords: work folder workspace files write read execute run command rights allow ask deny MACAIMAGIC.md learned
---
Give the model a folder, and it can really work there: read and write files, run scripts, read log files, and keep improving until things work.

## Choosing a work folder
Click **Work folder** in the chat and choose a folder. It applies to that conversation and is shown at the top of it.

## Rights: R W X
Next to the folder button are three letters. For each kind of action you choose **Allow**, **Ask first** or **Deny**:
- **R – Read**: look at folders and read files (default: allow)
- **W – Write**: create and change files (default: ask first)
- **X – Execute**: run commands, scripts and apps (default: ask first)

With "ask first" a card shows exactly what the model wants to do. Choose **Allow**, **Deny** or **Always in this conversation**.

> The model can only write inside the work folder. A link that points outside the folder does not work.

## MACAIMAGIC.md: notes and what the model learns
- Put a file **MACAIMAGIC.md** in the work folder with what the model should know about it, such as how to start an emulator. It is read again for every message.
- After a task of a few steps, the model writes under *Learned* what worked and what did not, so it does not make that mistake again. You can turn this off under Settings → Chat → Work folder.

## Good to know
- Programs with a window (an emulator, an app) are started on their own, so a command's time-out does not close them.
- Commands cannot ask for a password: `sudo` does not work here. For settings that need administrator rights there is *System management*.
