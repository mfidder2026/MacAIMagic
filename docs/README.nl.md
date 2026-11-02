# MacAIMagic (Nederlands)

Draai **DeepSeek-V4.1-Flash-1017** (748 miljard parameters), **GLM-5.3-Flash** (321 miljard) en **Qwen3.8-Flash-Next** (180 miljard) volledig lokaal
op een Mac met Apple Silicon en 128 GB unified memory. MacAIMagic is een eigen macOS-app met live grafieken. Je kunt
chatten, afbeeldingen uploaden, het web laten doorzoeken, modellen naast elkaar vergelijken, en het model gebruiken als
OpenAI- of Anthropic-compatibele API (bijvoorbeeld vanuit Claude Code).

De Engelse [README](../README.md) is de volledige versie; dit is een samenvatting.

## Modellen

| Model | Download | In geheugen | Schrijven | Prompt lezen |
|---|---|---|---|---|
| **Qwen3.8-Flash-Next Q4**: 180B, 6B actief, 4 bit, MTP | 116 GB | past (83 GB) | **33 tok/s, 40–55 met MTP** | ~440 tok/s |
| **GLM-5.3-Flash Compact**: experts 2–3 bit, MTP | 110 GB | past (109 GB) | **20 tok/s, 25–29 met MTP** | ~175–185 tok/s |
| **DeepSeek-V4.1-Flash Compact**: experts 1,6 bit, attention 8 bit | 278 GB | past (115 GB) | **19,6–20,1 tok/s** | ~160–175 tok/s |
| **GLM-5.3-Flash Q4**: 4 bit | 201 GB | ~95 GB experts in de GPU-cache, de rest van de SSD | **5–6 tok/s** | ~70–100 tok/s |
| **DeepSeek-V4.1-Flash Q4**: 4 bit, vrijwel gelijk aan het origineel | 460 GB | ~95 GB experts in de GPU-cache, de rest van de SSD | **7–8,5 tok/s** | ~65–95 tok/s |

Gemeten op een MacBook Pro M3 Max (128 GB), 64K context, vision aan, standaard GPU-limiet van macOS. De Q4-modellen met
de GPU-limiet verhoogd naar 120 GB (knop onder Modellen); van een koude start tot een warme (de expert-cache van de
vorige keer).

- **Compact**: alles wat per woord nodig is, staat in het geheugen. Snel.
- **MTP**: GLM en Qwen raden de volgende woorden vooruit en het model controleert ze in één keer. Zelfde antwoorden,
  tot 65% sneller schrijven.
- **Q4**: dichter bij het origineel, maar groter dan 128 GB. De GPU houdt de experts die het gesprek het meest gebruikt
  (~95 GB) in een cache; de rest komt met veel parallelle leesacties van de SSD (6 GB/s). Na een herstart laadt de
  cache zichzelf terug, zodat ook het eerste antwoord meteen op snelheid is. Verhoog daarvoor de GPU-limiet met de knop
  onder Modellen (zie [RESEARCH.md](RESEARCH.md)).
- **Talen**: Nederlands, Engels, Duits of Frans (Instellingen → Taal; eerst de taal van je Mac). Ook het model krijgt zijn instructies in die taal.
- **Afbeeldingen plakken**: ⌘V in het invoerveld, ook tijdens het typen (schermafbeeldingen, gekopieerde plaatjes, afbeeldingsbestanden uit de Finder).
- **Context**: bovenin de chat zie je hoeveel van de context van het model een gesprek inneemt (standaard 64K, tot 1M voor DeepSeek en GLM, 256K voor Qwen). Bij 80% vat het model het begin van het gesprek samen; de berichten blijven zichtbaar, met een markering. Er is ook een knop om het meteen te doen.
- **Werkmap per chat**: het model kan in een map die jij per gesprek kiest bestanden lezen, maken en aanpassen, scripts starten en logs
  lezen. Wat het mag, stel je in met het knopje **L S U** (lezen, schrijven, uitvoeren) naast de werkmap: per soort Toestaan, Eerst vragen of Weigeren (standaard mag lezen en vraagt de rest eerst). Een bestand `MACAIMAGIC.md` in de werkmap geeft het model vaste instructies voor die map, bijvoorbeeld hoe het een emulator start. Algemene instructies voor elk gesprek zet je in `~/Library/Application Support/MacAIMagic/MACAIMAGIC.md` (Instellingen → Chat → Open bestand). Beide worden bij elk bericht opnieuw gelezen.

## Cluster

Verbind meerdere Macs met Thunderbolt en gebruik hun geheugen samen. Op de extra Macs kies je in MacAIMagic onder
**Cluster** de rol **Helper** en druk je op **Start helper**; op de hoofd-Mac verschijnen ze vanzelf. Elke helper neemt
zoveel hele lagen als zijn GPU kan houden; de hoofd-Mac de rest, zo nodig met de expert-cache. Met een MacBook Pro
M3 Max (128 GB), een Mac Studio M5 (96 GB) en een Mac Studio M1 (32 GB) heb je samen ~256 GB: GLM-5.3-Flash Q4 past dan
helemaal in het geheugen, en van DeepSeek-V4.1-Flash Q4 staat bijna de helft van de experts van de hoofd-Mac in de cache.
Op een helper verhoogt **Verhoog GPU-limiet** wat zijn GPU mag gebruiken (bij 96 GB van ~72 naar ~88 GB). Getest op één
Mac met een lokale helper: het verdelen kost ~7% schrijfsnelheid.

## Installeren

```sh
brew install cmake
./scripts/build_engine.sh     # llama.cpp ophalen, patchen en bouwen met Metal
./scripts/make_app.sh         # dist/MacAIMagic.app bouwen
open dist/MacAIMagic.app
```

Of gebruik de kant-en-klare build. Die is niet door Apple genotariseerd, dus macOS blokkeert hem na een download met de
browser ("Apple kan niet verifiëren dat MacAIMagic vrij is van malware"). Installeer hem daarom het makkelijkst vanuit
Terminal; een download met `curl` krijgt geen quarantaine-label:

```sh
curl -L https://github.com/mfidder2026/MacAIMagic/releases/latest/download/MacAIMagic-macOS-arm64.zip -o /tmp/MacAIMagic.zip && ditto -x -k /tmp/MacAIMagic.zip /Applications && open /Applications/MacAIMagic.app
```

Heb je hem met de browser gedownload: zet de app in `/Applications` en voer eenmalig
`xattr -dr com.apple.quarantine /Applications/MacAIMagic.app` uit, of open de app één keer en klik dan in
Systeeminstellingen → Privacy en beveiliging op **Toch openen** (rechtsklik → Open werkt sinds macOS 15 niet meer).

Download modellen in de app (Modellen → **Download**), met `tools/download_model.sh <model-id>`, of met de hand via de
links in [`tools/models.json`](../tools/models.json). Elk model staat in een eigen map met zijn id als naam; de
vision-bestanden staan in `vision/`.

## Claude Code met het lokale model

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude
```

## Licenties

MacAIMagic: MIT. llama.cpp: MIT. DeepSeek-V4.1-Flash-1017 en GLM-5.3-Flash (en hun gequantiseerde bestanden): MIT. Qwen3.8-Flash-Next: Qwen-licentie.
