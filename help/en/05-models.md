---
title: Models
icon: square.stack.3d.up
keywords: model download compact Q4 MTP memory SSD GPU limit update delete fast heavy images model folder
---
## Which model?
Each card says for this Mac whether the model **fits whole in memory**, **streams from the SSD** (slower) or is **too big**. **System** recommends the best model that fits whole.

| Kind | What it means |
|---|---|
| **Compact** | Everything a token needs stays in memory. The fast choice. |
| **Q4** | Closer to the original weights, but larger than 128 GB: the experts used most stay on the GPU, the rest comes from the SSD. |
| **MTP** | GLM and Qwen guess the next tokens ahead; the same answers, up to 65% faster writing. On/off under Settings → Engine. |

## Buttons on a card
- **Download**: carries on after an interruption, and every file is checked (sha256).
- **Check for update**: sees within seconds whether there is a newer version, without reading the whole model.
- **Start** / **Stop**: loads the model into the engine.
- **Fast** / **Heavy**: which model Documents uses for small work and for writing.
- **Choose for images**: the model for Images.
- **Delete model**: frees the disk space (stop the model first).

## More memory for the GPU
**Raise GPU limit** lets the GPU wire more memory. It asks for your password and lasts until the next restart.

## Model folder
By default the models are in `~/Library/Application Support/MacAIMagic/models`. Choose another folder, such as an external SSD, under Models → Model folder → **Choose folder…**.
