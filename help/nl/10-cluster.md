---
title: Cluster: meerdere Macs
icon: point.3.connected.trianglepath.dotted
keywords: cluster helper Thunderbolt meerdere Macs geheugen RPC netwerk
---
Met meerdere Macs is er één **hoofd-Mac** (daar chat je) en zijn de andere **helpers**, die een deel van het model op hun GPU houden.

## Instellen
1. Verbind elke helper met een **Thunderbolt-kabel** met de hoofd-Mac (Systeeminstellingen → Netwerk → Thunderbolt Bridge: verbonden).
2. Op elke helper: **Cluster** → rol **Helper** → **Start helper**.
3. Op de hoofd-Mac staan de helpers onder **Cluster**, met hun chip en geheugen. Vink ze aan en start een model.
4. **Verhoog GPU-limiet** op een helper laat die meer lagen nemen.

## Vraag het de app
Je kunt het cluster ook in de chat laten bouwen. Zeg op elke andere Mac "word helper", en op de hoofd-Mac "zoek de helpers, gebruik ze en start het model". Het model laat elke stap eerst op een kaart zien.

## Als het laden lang duurt
- Voor een start vraagt de app elke helper een paar seconden of hij antwoordt. Een helper die niet antwoordt, doet niet mee met die start, en onder **Cluster** staat waarom: de helper staat niet aan, de kabel of het netwerk is weg, of de firewall op die Mac houdt de verbinding tegen.
- Tijdens het laden zie je hoeveel van het model al naar de helpers is gestuurd en hoe snel. De eerste keer gaat alles over de kabel; een helper houdt wat hij kreeg, dus een volgende start gaat sneller. Gaat er 90 seconden niets meer heen, dan zegt de app dat.

## Mac en Windows samen
Een pc met WinAIMagic kan helper zijn voor een Mac, en andersom: beide gebruiken dezelfde versie van het helperprogramma en vinden elkaar onder dezelfde naam op het netwerk. Dit is nog niet met echte machines geprobeerd.

## Veiligheid
Een helper luistert alleen op de Thunderbolt-verbinding, tenzij je het lokale netwerk toestaat. De verbinding heeft geen wachtwoord: gebruik een directe kabel of een netwerk dat je vertrouwt.

> De eerste start stuurt elke helper zijn lagen. Een helper bewaart ze in `~/Library/Caches/llama.cpp/rpc`; verwijder die map om ruimte vrij te maken.
