# MacDeepSeek

DeepSeek-V4.1-Flash-1017 (748 miljard parameters, MoE) volledig lokaal draaien op een MacBook Pro M3 Max met 128 GB,
met een eigen macOS-app om mee te praten: afbeeldingen uploaden, web zoeken, nadenken aan/uit, en een
OpenAI-/Anthropic-compatibele API voor andere programma's (zoals Claude Code).

## Waarom niet gewoon PolyStrata of Project Maya?

| | PolyStrata | Project Maya | MacDeepSeek |
|---|---|---|---|
| Platform | Windows/Linux, NVIDIA/AMD | Linux/Windows, NVIDIA/AMD | **macOS, Apple Silicon** |
| DeepSeek-V4.1-Flash-1017 | nee (alleen V4 Flash, Linux) | ja, maar niet op Mac | **ja** |
| Mac-ondersteuning | alleen Qwen3.8 | experimenteel, alleen GLM-5.3 | doel van dit project |
| Kernidee | experts verdelen over VRAM/RAM | experts in lagen: GPU → RAM → SSD | **één geheugen: GPU en CPU delen dezelfde 128 GB** |

Beide projecten lossen hetzelfde probleem op: een model dat groter is dan het videogeheugen. Ze houden de
vaak gebruikte "experts" op de videokaart en de rest in RAM of op de SSD, en moeten die over de PCIe-bus heen en weer
kopiëren. Een Mac heeft dat probleem niet: CPU en GPU delen één pool van 128 GB unified memory met ~400 GB/s.
Daarom kan op deze Mac **het hele model (115 GB) in het geheugen**, zonder kopiëren.

## Hoe het werkt

- **Model:** de [Maya-XS-quantisatie](https://huggingface.co/peasantsmith/DeepSeek-V4.1-Flash-1017-Maya-GGUF) van
  Project Maya, die speciaal gemaakt is om in 128 GB te passen: experts in IQ1_S, attention/shared experts in Q8_0,
  87,5% dezelfde top-token als het origineel. De vision tower komt van Unsloth (`mmproj-F16.gguf`).
- **Engine:** llama.cpp (gepind op commit `ddf48f8`, met native `deepseek41`-ondersteuning en Metal) plus een eigen
  patch (`patches/0001-deepseek41-maya-engram.patch`): llama.cpp verwacht de Engram-tabellen als één tensor met
  `ple.*`-metadata, terwijl Maya twee tabellen per Engram-laag met `engram.*`-metadata gebruikt. De patch laat
  llama.cpp beide lezen.
- **Geheugenplan (in de app):** leest de GGUF-headers en berekent per laag wat waar komt:

  | Onderdeel | Grootte | Waar |
  |---|---|---|
  | Vaste gewichten (attention, shared experts, router, mHC) | 9,2 GB | GPU |
  | Routed experts, 40 lagen | 106,2 GB | GPU, zo veel lagen als onder de GPU-limiet passen; de rest via CPU uit de page cache |
  | Engram n-gram-tabellen | 161,3 GB | SSD, een paar rijen per token (lazy read) |
  | KV-cache + buffers (64K context, vision) | ~4,8 GB | GPU |

  macOS laat de GPU standaard ~115 GB vastzetten. Met de knop **"Verhoog GPU-limiet"** (`sysctl iogpu.wired_limit_mb`,
  vraagt je wachtwoord, geldt tot herstart) passen alle experts op de GPU.

## Wat de app kan

- Chat met streaming antwoorden, markdown en codeblokken met kopieerknop
- **Denken** aan/uit, met inklapbare gedachtegang en instelbaar denkniveau
- **Afbeeldingen**: knop, slepen of plakken (⌘V); worden verkleind tot 1344 px
- **Web zoeken**: het model roept zelf `web_search` en `fetch_url` aan; de app voert die uit (DuckDuckGo, of
  Brave Search met een eigen API-sleutel) en toont de stappen en bronnen
- Gesprekken worden bewaard in `~/Library/Application Support/MacDeepSeek/`
- Dashboard: model downloaden (hervatbaar, sha256-gecontroleerd), geheugenplan, engine starten/stoppen, log
- API op `http://127.0.0.1:8080`: OpenAI (`/v1`), Anthropic (`/v1/messages`) en Responses (`/v1/responses`)

## Installeren

```sh
brew install cmake                 # eenmalig
./scripts/build_engine.sh          # llama.cpp ophalen, patchen en bouwen met Metal (~5 min)
./scripts/make_app.sh              # dist/MacDeepSeek.app bouwen
open dist/MacDeepSeek.app
```

Download het model via de app (Engine & model → Download model), of met `tools/download_model.sh`. Dat is
278 GB; bij ~80 MB/s duurt het ongeveer een uur. Daarna: **Start engine**. Het eerste laden duurt enkele minuten.

### Claude Code met het lokale model

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude
```

## Tips voor snelheid

- Sluit grote programma's (browsers met veel tabbladen, Docker) voordat je de engine start: het model gebruikt
  ~120 GB van de 128 GB.
- Verhoog de GPU-limiet (knop in het dashboard), zodat alle experts op de GPU draaien.
- Kortere context (32K) laat meer ruimte over; 64K is de standaard.
- Zet "Denken" uit voor snelle, eenvoudige vragen.

## Gemeten op de M3 Max (128 GB)

Maya-XS, 64K context, vision aan, macOS-standaard GPU-limiet (115 GB), experts van 2 lagen via de CPU:

| | Snelheid |
|---|---|
| Schrijven (decode) | **19–21 tokens/s**, ook met denken aan |
| Prompt lezen (2.600 tokens) | **~160 tokens/s** (16 s) |
| Afbeelding (200 tokens) | ~2 s |
| Laden | ~1 min de eerste keer, daarna ~8 s (uit de page cache) |
| Geheugen | 115 GB vastgezet voor de GPU, ~10 GB vrij voor macOS |

Wat we leerden bij het afstemmen:
- `--ubatch-size 1024` leest prompts ~20% sneller dan de standaard 512.
- `--ubatch-size 2048` maakt de buffers te groot: het geheugen loopt over en schrijven zakt naar 3 tokens/s.
- Meer lagen naar de CPU (4 i.p.v. 2) kost ~10%; alles op de GPU zou het lezen maar weinig sneller maken.
  Het lezen van lange prompts is nu de zwakke plek (een webpagina van 10.000 tokens ≈ 1 minuut).

## Status

- [x] Onderzoek PolyStrata en Project Maya, modelkeuze en geheugenplan
- [x] llama.cpp-patch voor Maya-GGUF's (Engram-tabellen)
- [x] macOS-app (SwiftUI): chat, afbeeldingen, web zoeken, dashboard, API
- [x] Unit tests (geheugenplan, GGUF-headers van het echte model, markdown, zoekresultaten)
- [x] Engine gebouwd en end-to-end getest met het echte model: chat, denken, afbeeldingen, tool calls en
      de zoeklus van de app (zoeken → pagina's lezen → antwoord met bronnen)
- [ ] Prompt lezen versnellen (Metal-kernels voor IQ1_S-experts bij grote batches)

## Mappen

```
App/                 SwiftUI-app (Swift Package)
patches/             llama.cpp-patch + gepinde commit
scripts/             build_engine.sh, make_app.sh, make_icon.swift
tools/               download_model.sh, gguf_peek.py (GGUF-headers lezen, ook via HTTP)
third_party/         llama.cpp en project-maya (niet in git)
```

## Licenties

MacDeepSeek: MIT. llama.cpp: MIT. Het model DeepSeek-V4.1-Flash-1017 en de Maya-quants: MIT.
