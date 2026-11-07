---
title: Cluster: several Macs
icon: point.3.connected.trianglepath.dotted
keywords: cluster helper Thunderbolt several Macs memory RPC network
---
With several Macs, one is the **main Mac** (you chat there) and the others are **helpers** that hold part of the model on their GPU.

## Setting up
1. Connect each helper to the main Mac with a **Thunderbolt cable** (System Settings → Network → Thunderbolt Bridge: connected).
2. On each helper: **Cluster** → role **Helper** → **Start helper**.
3. On the main Mac, **Cluster** lists the helpers with their chip and memory. Tick them and start a model.
4. **Raise GPU limit** on a helper lets it take more layers.

## Ask the app
You can also have the cluster built from the chat. Say "become a helper" on each other Mac, and on the main Mac "find the helpers, use them and start the model". The model shows each step on a card first.

## When loading takes long
- Before a start the app asks each helper for a few seconds whether it answers. A helper that does not answer stays out of that start, and **Cluster** says why: the helper is not on, the cable or network is gone, or the firewall on that Mac blocks the connection.
- While loading you see how much of the model has gone to the helpers and how fast. The first time everything goes over the cable; a helper keeps what it got, so a next start is faster. If nothing goes out for 90 seconds, the app says so.

## Mac and Windows together
A PC with WinAIMagic can be a helper for a Mac, and the other way round: both use the same version of the helper program and find each other under the same name on the network. This has not been tried with real machines yet.

## Security
A helper only listens on the Thunderbolt connection, unless you allow the local network. The connection has no password: use a direct cable or a network you trust.

> The first start sends each helper its layers. A helper keeps them in `~/Library/Caches/llama.cpp/rpc`; delete that folder to free the space.
