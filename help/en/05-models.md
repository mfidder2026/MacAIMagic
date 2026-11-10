---
title: Models
icon: square.stack.3d.up
keywords: model small Ling Ministral download compact Q4 MTP memory SSD GPU limit update delete fast heavy images model folder repeated text ngram
---
## Which model?
Each card says for this Mac whether the model **fits whole in memory**, **streams from the SSD** (slower) or is **too big**. **System** recommends the best model that fits whole.

| Kind | What it means |
|---|---|
| **Compact** | Everything a token needs stays in memory. The fast choice. |
| **Q4** | Closer to the original weights, but larger than 128 GB: the experts used most stay on the GPU, the rest comes from the SSD. |
| **MTP** | GLM and Qwen guess the next tokens ahead; the same answers, up to 65% faster writing. On/off under Settings → Engine. Below it, **Write repeated text faster**: changing code goes up to twice as fast with it. |

**For a Mac with 8 or 16 GB** there are two small models. **Ministral-3-8B** also reads images and is recommended on 16 GB. **Ling-3.0-tiny** uses only 1B of its 8B per word, which makes it three times as fast, but it reads no images. It is recommended on 8 GB, where macOS keeps most of it in memory and reads the rest from the SSD.

## Buttons on a card
- **Download**: carries on after an interruption, and every file is checked (sha256).
- **Check for update**: sees within seconds whether there is a newer version, without reading the whole model.
- **Start** / **Stop**: loads the model into the engine, or takes it out. While it loads or unloads a round gauge with a percentage runs, in the status at the top and in the chat; it goes by how long it took the time before.
- **Fast** / **Heavy**: which model Documents uses for small work and for writing.
- **Choose for images**: the model for Images.
- **Delete model**: frees the disk space (stop the model first).

## More memory for the GPU
**Raise GPU limit** lets the GPU wire more memory. It asks for your password and lasts until the next restart.

## Model folder
By default the models are in `~/Library/Application Support/MacAIMagic/models`. Choose another folder, such as an external SSD, under Models → Model folder → **Choose folder…**.
