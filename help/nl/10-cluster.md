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

## Veiligheid
Een helper luistert alleen op de Thunderbolt-verbinding, tenzij je het lokale netwerk toestaat. De verbinding heeft geen wachtwoord: gebruik een directe kabel of een netwerk dat je vertrouwt.

> De eerste start stuurt elke helper zijn lagen. Een helper bewaart ze in `~/Library/Caches/llama.cpp/rpc`; verwijder die map om ruimte vrij te maken.
