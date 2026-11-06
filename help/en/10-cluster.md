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

## Security
A helper only listens on the Thunderbolt connection, unless you allow the local network. The connection has no password: use a direct cable or a network you trust.

> The first start sends each helper its layers. A helper keeps them in `~/Library/Caches/llama.cpp/rpc`; delete that folder to free the space.
