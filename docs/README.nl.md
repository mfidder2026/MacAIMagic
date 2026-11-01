# MacDeepSeek (Nederlands)

Draai **DeepSeek-V4.1-Flash-1017** (748 miljard parameters), **GLM-5.3-Flash** (321 miljard) en **Qwen3.8-Flash-Next** (180 miljard) volledig lokaal
op een Mac met Apple Silicon en 128 GB unified memory. MacDeepSeek is een eigen macOS-app met live grafieken. Je kunt
chatten, afbeeldingen uploaden, het web laten doorzoeken, modellen naast elkaar vergelijken, en het model gebruiken als
OpenAI- of Anthropic-compatibele API (bijvoorbeeld vanuit Claude Code).

De Engelse [README](../README.md) is de volledige versie; dit is een samenvatting.

## Modellen

| Model | Download | In geheugen | Schrijven | Prompt lezen |
|---|---|---|---|---|
| **Qwen3.8-Flash-Next Q4**: 180B, 6B actief, 4 bit, MTP | 116 GB | past (83 GB) | **33 tok/s, 40–55 met MTP** | ~440 tok/s |
| **GLM-5.3-Flash Compact**: experts 2–3 bit, MTP | 110 GB | past (109 GB) | **20 tok/s, 25–29 met MTP** | ~175–185 tok/s |
| **DeepSeek-V4.1-Flash Compact**: experts 1,6 bit, attention 8 bit | 278 GB | past (115 GB) | **19,6–20,1 tok/s** | ~160–175 tok/s |
| **GLM-5.3-Flash Q4**: 4 bit | 201 GB | 75 GB van de SSD | ~2,2 tok/s | ~8 tok/s |
| **DeepSeek-V4.1-Flash Q4**: 4 bit, vrijwel gelijk aan het origineel | 460 GB | 173 GB van de SSD | ~2,8 tok/s | ~9 tok/s |

Gemeten op een MacBook Pro M3 Max (128 GB), 64K context, vision aan, standaard GPU-limiet van macOS.

- **Compact**: alles wat per woord nodig is, staat in het geheugen. Snel.
- **MTP**: GLM en Qwen raden de volgende woorden vooruit en het model controleert ze in één keer. Zelfde antwoorden,
  tot 65% sneller schrijven.
- **Q4**: dichter bij het origineel, maar groter dan 128 GB. Op één Mac veel te traag; bedoeld voor 256 GB of twee
  gekoppelde Macs (zie [RESEARCH.md](RESEARCH.md)).
- **Werkmap per chat**: het model kan in een map die jij per gesprek kiest bestanden lezen, maken en aanpassen, scripts starten en logs
  lezen. Schrijven en commando's vragen eerst jouw toestemming.

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

MacDeepSeek: MIT. llama.cpp: MIT. DeepSeek-V4.1-Flash-1017 en GLM-5.3-Flash (en hun gequantiseerde bestanden): MIT. Qwen3.8-Flash-Next: Qwen-licentie.
