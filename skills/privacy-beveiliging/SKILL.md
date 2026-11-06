---
name: privacy-beveiliging
description: Security and privacy (firewall, Gatekeeper, FileVault, SIP status, privacy permissions, screen lock). Sensitive: read this before any security change.
platform: macos
---
Tested on macOS 27. These settings protect the Mac. The app warns the user for each of them; you explain in plain words
what the change means and how to turn it back, before the plan.

Read: `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`, `… --getstealthmode`, `… --listapps`,
`spctl --status` (Gatekeeper), `fdesetup status` (FileVault), `csrutil status` (SIP), `profiles list`.

| What | check | apply | undo | admin |
|---|---|---|---|---|
| Firewall on/off | `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate` | `/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on` (or off) | the opposite | yes |
| Stealth mode | `… --getstealthmode` | `… --setstealthmode on` | `… --setstealthmode off` | yes |
| Allow one app through the firewall | `… --listapps` | `… --add /Applications/<App>.app; … --unblockapp /Applications/<App>.app` | `… --remove /Applications/<App>.app` | yes |
| Password right after sleep | `sysadminctl -screenLock status` | `sysadminctl -screenLock immediate -password -` | `sysadminctl -screenLock off -password -` | no (it asks for the password itself) |

Cannot be scripted — open System Settings and say what to click:
- Gatekeeper ("Allow apps from anywhere"): `open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"`
- FileVault on: same pane, FileVault. Tell the user to keep the recovery key safe.
- Privacy permissions (camera, microphone, screen recording, full disk access): same pane, Privacy.
- SIP can only be changed from Recovery; never advise turning it off unless the user knows exactly why.
