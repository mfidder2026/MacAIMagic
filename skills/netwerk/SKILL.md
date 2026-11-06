---
name: netwerk
description: Network (DNS servers, Wi-Fi, IP address, network services, proxy, flush DNS cache)
platform: macos
---
Tested on macOS 27. First list the services: `networksetup -listallnetworkservices` (for example "Wi-Fi",
"USB 10/100/1000 LAN", "Thunderbolt Bridge"). Use the exact service name, in quotes.

Read: `networksetup -getdnsservers "Wi-Fi"`, `networksetup -getinfo "Wi-Fi"`, `networksetup -getairportnetwork en0`,
`scutil --dns`, `scutil --proxy`, `networksetup -getwebproxy "Wi-Fi"`, `ifconfig -a`.

| What | check | apply | undo | admin |
|---|---|---|---|---|
| DNS servers | `networksetup -getdnsservers "Wi-Fi"` | `networksetup -setdnsservers "Wi-Fi" 1.1.1.1 1.0.0.1` | `networksetup -setdnsservers "Wi-Fi" <old servers>`, or `Empty` when the check said "There aren't any DNS Servers" | yes |
| Wi-Fi off/on | `networksetup -getairportpower en0` | `networksetup -setairportpower en0 off` | `networksetup -setairportpower en0 on` | no |
| Flush DNS cache | (none: `echo flushed`) | `dscacheutil -flushcache; killall -HUP mDNSResponder` | (none: `echo nothing to undo`) | yes |

Turning off the network the conversation runs over (Wi-Fi on a Mac without cable) cuts web search: warn first.
Never change the proxy unless the user asks for it and gives the address.
