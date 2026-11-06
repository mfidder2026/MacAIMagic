---
title: Skills
icon: book.closed
keywords: skills instructies SKILL.md eigen onderwerp
---
Een **skill** is een korte handleiding voor het model over één onderwerp, met commando's die op deze macOS-versie getest zijn. Het model ziet alleen de namen en laadt een skill pas als het hem nodig heeft. Zo blijft de prompt kort en het model snel.

## Aan of uit
Skills staan standaard aan. Uitzetten kan onder Instellingen → **Systeembeheer** → **Skills**.

## Ingebouwde skills
| Skill | Over |
|---|---|
| uiterlijk | donkere modus, accentkleur, Dock, Finder, schermafbeeldingen |
| energie | slaapstand, scherm uit, Power Nap, batterij |
| netwerk | DNS, wifi, IP-adres, DNS-cache legen |
| software | Homebrew, macOS-updates |
| opstartitems | programma's die bij het inloggen starten, achtergronddiensten |
| opslag | wat ruimte inneemt, veilig opruimen via de prullenmand |
| privacy-beveiliging | firewall, Gatekeeper, FileVault, privacyrechten |
| diagnose | traag, warm, batterij snel leeg, crashes, netwerkproblemen |

## Een eigen skill maken
1. Instellingen → Systeembeheer → **Open map**.
2. Maak een map, bijvoorbeeld `mijn-printer`, met daarin een bestand `SKILL.md`:
```
---
name: mijn-printer
description: De printer op kantoor installeren en herstellen
platform: macos
---
Schrijf hier de stappen en commando's.
```
3. Een eigen skill met dezelfde naam als een ingebouwde, vervangt die ingebouwde.
