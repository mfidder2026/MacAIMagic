# MacDeepSeek (Nederlands)

Draai **DeepSeek-V4.1-Flash-1017** (748 miljard parameters) en **GLM-5.3-Flash** (321 miljard parameters) volledig lokaal
op een Mac met Apple Silicon en 128 GB unified memory. MacDeepSeek is een eigen macOS-app met live grafieken. Je kunt
chatten, afbeeldingen uploaden, het web laten doorzoeken, modellen naast elkaar vergelijken, en het model gebruiken als
OpenAI- of Anthropic-compatibele API (bijvoorbeeld vanuit Claude Code).

De Engelse [README](../README.md) is de volledige versie; dit is een samenvatting.

## Modellen

| Model | Download | In geheugen | Schrijven | Prompt lezen |
|---|---|---|---|---|
| **DeepSeek-V4.1-Flash Compact**: experts 1,6 bit, attention 8 bit | 278 GB | past (115 GB) | **19,6–20,1 tok/s** | ~160–175 tok/s |
| **GLM-5.3-Flash Compact**: experts 2–3 bit | 110 GB | past (109 GB) | **19,9–20,4 tok/s** | ~175–180 tok/s |
| **DeepSeek-V4.1-Flash Q4**: 4 bit, vrijwel gelijk aan de originele FP4-experts | 502 GB | streamt van de SSD | wordt gemeten | wordt gemeten |
| **GLM-5.3-Flash Q4**: 4 bit | 201 GB | streamt van de SSD | wordt gemeten | wordt gemeten |

Gemeten op een MacBook Pro M3 Max (128 GB), 64K context, vision aan, standaard GPU-limiet van macOS.

- **Compact**: alles wat per woord nodig is, staat in het geheugen. Snel.
- **Q4**: dichter bij het origineel, maar groter dan het geheugen. Experts die niet passen, komen tijdens het schrijven
  van de SSD. Trager, maar nauwkeuriger.

## Installeren

```sh
brew install cmake
./scripts/build_engine.sh     # llama.cpp ophalen, patchen en bouwen met Metal
./scripts/make_app.sh         # dist/MacDeepSeek.app bouwen
open dist/MacDeepSeek.app
```

Of gebruik de kant-en-klare build in [`RELEASE/`](../RELEASE/).

Download modellen in de app (Modellen → **Download**), met `tools/download_model.sh <model-id>`, of met de hand via de
links in [`tools/models.json`](../tools/models.json). Elk model staat in een eigen map met zijn id als naam; de
vision-bestanden staan in `vision/`.

## Claude Code met het lokale model

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude
```

## Licenties

MacDeepSeek: MIT. llama.cpp: MIT. DeepSeek-V4.1-Flash-1017 en GLM-5.3-Flash, en de gequantiseerde bestanden: MIT.
