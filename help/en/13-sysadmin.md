---
title: System management
icon: gearshape.2
keywords: system set up configure macOS administrator admin password plan approve undo snapshot warning firewall Dock sleep diagnosis
---
With system management you ask the model, in plain words, to look at this Mac or set it up:
- "Why is my Mac so slow?"
- "Put the Dock on the left and hide it automatically"
- "Set display sleep to 30 minutes"
- "Install VLC"

## On or off
System management is on by default. Turn it off under Settings → **System management** → **The model may look at and set up this Mac**; the model then gets no tools for this Mac.

## Looking and changing
- **Looking** (diagnosis): the model reads settings with fixed commands that cannot change anything. By default this is allowed without asking.
- **Changing**: the model makes a **plan**. You see every step, with the value it has now. Only after **Allow** does the app carry out the plan. Then it reads every value again, as a check.

You set both rights under Settings → System management: **Allow**, **Ask first** or **Deny**.

## Administrator rights
Some settings, such as sleep, DNS and the firewall, need administrator rights. Such a plan shows 🔑:
- it **always** asks first, even when you chose "always in this conversation";
- then **macOS itself** asks for your password. MacAIMagic and the model never see that password;
- the box **Make a local snapshot first** makes a Time Machine snapshot beforehand. It is on by default.

## Warnings
Sensitive changes are not blocked, but they get a **red warning** that says what they mean. For example: turning off the firewall or Gatekeeper, FileVault, user accounts, privacy permissions, deleting files for good, or a restart. A plan that follows reading the web gets a warning too.

## Undo
- Ask the model: "undo the last change". It knows which change it was, and you approve putting it back on a card first.
- The app keeps every change in the background, with the values from before. So the model can put a change back in a later conversation too.
- For app settings (`defaults`) the app keeps an exact copy beforehand. That way it can put them back even when the model's undo is wrong.
- Afterwards the app checks whether everything is as it was, and says so when it is not.

## What cannot be done
macOS does not let some things be done with commands: privacy permissions (camera, microphone, screen recording), turning on FileVault, turning off Gatekeeper completely, and SIP. The model then opens the right pane of System Settings and tells you what to click.

> Start with diagnosis: it only reads and changes nothing. With a change, always look at the card before you press Allow.
