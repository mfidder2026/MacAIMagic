# MacAIMagic (Nederlands)

Draai **DeepSeek-V4.1-Flash-1017** (748 miljard parameters), **GLM-5.3-Flash** (321 miljard), **Qwen3.8-Flash-Next** (180 miljard) en **Qwen3.6-35B-A3B** volledig lokaal
op een Mac met Apple Silicon. Met 128 GB draait elk model, met 32 GB Qwen3.6-35B-A3B; de app rekent zelf uit wat past.
MacAIMagic is een eigen macOS-app met live grafieken. Je kunt
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
| **Qwen3.6-35B-A3B Q4**: 35B, 3B actief, 4 bit; het model voor een Mac met 32 GB | 23 GB | past (22 GB) | **60–67 tok/s** | ~180 tok/s (korte prompt) |
| **Qwen3.6-35B-A3B Heretic Q4**: hetzelfde model zonder weigeringen ([Heretic](https://huggingface.co/llmfan46/Qwen3.6-35B-A3B-uncensored-heretic-GGUF)), 4 bit | 21 GB | past (21 GB) | **78–80 tok/s**¹ | ~1.180 tok/s¹ |
| **Ministral-3-8B Q4**: 8B, 4 bit, leest afbeeldingen; het model voor een Mac met 8 of 16 GB | 6 GB | past (5 GB) | **51 tok/s** | ~630 tok/s |

¹ Gemeten in de app, in een gesprek met tools (een prompt van 2.831 tokens), nog niet met de benchmark van de andere regels.

**Systeemcontrole**: bij elke start controleert de app (zijbalk → **Systeem**) de engine, het downloadgereedschap, de
modellen, de schijfruimte, de GPU-limiet en de ontwikkeltools van Apple. Wat hij zelf kan oplossen doet hij, de rest
biedt hij aan met één knop. Hij raadt het beste model aan dat helemaal in het geheugen van deze Mac past (128 GB:
DeepSeek-V4.1-Flash Compact, 96 GB: Qwen3.8-Flash-Next, 32 GB: Qwen3.6-35B-A3B), of de rol van helper in een cluster.
Op een Mac met weinig geheugen verkleint de app de context tot wat nog past en zet hij vision zo nodig uit (op 32 GB:
Qwen3.6 met 32K context). Grotere modellen blijven beschikbaar en streamen van de SSD, ook op 32 GB (gemeten: DeepSeek
Compact ~5 tok/s, zie [RESEARCH](RESEARCH.md)). Er zijn geen ontwikkeltools, Python of Homebrew nodig om de app te gebruiken.

**Leert van fouten**: een werkmap krijgt een `MACAIMAGIC.md` als die er nog niet is. Na een taak van een paar stappen
zegt het model wat het heeft vastgesteld (wat werkte, wat mislukte en waarom) en zet de app dat onder *Geleerd*, zodat een
volgend gesprek in die map het weet. Niet na een taak die het web las; je kunt het bestand aanpassen, en dit uitzetten in
de instellingen.

**Werkt door tot het af is**: stopt een model terwijl de taak niet af is (het kondigt iets aan en stopt, of denkt alleen),
dan laat de app het automatisch doorgaan en zie je dat in het gesprek. Een lange taak met één vraag wordt samengevat als
de context volraakt.

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

## Documenten

Maak Word-documenten zonder cloud-AI (zijbalk → **Documenten**). Een project is een map met:

- **Bijlagen**: de context en informatie, bijvoorbeeld waar een AQS uit moet bestaan.
- **Huisstijl**: alleen de opmaak. Die komt als laatste: voorblad, kop- en voettekst, genummerde koppen, tabelopmaak en inhoudsopgave.
- **Gegevens voor het voorblad**: die vul je per project één keer in.

Zeg je "maak een AQS", dan kijkt het model eerst in de bijlagen waaruit het document moet bestaan. Wat daar niet staat, zoals
het onderwerp en regelgeving, zoekt het op internet. Klantgegevens gaan niet mee naar de zoekmachine. Daarna schrijft het
een concept in Markdown met genummerde bronnen, waarin je alle tekst aanpast. Het `.docx`-bestand komt pas als jij het
goedkeurt. Een snel model doet het kleine werk (notities per pagina, spelling), een zwaar model het schrijven; op een Mac
waar er geen twee passen, doet één model alles.

Nog niet in deze versie: vertalen en corrigeren in het Word-bestand zelf met bijgehouden wijzigingen, en opmerkingen.

## Beeld

Maak afbeeldingen op de Mac zelf (zijbalk → **Beeld**): beschrijf wat je wilt zien en FLUX.2 Klein 4B (5,3 GB, Apache 2.0)
maakt het. De afbeeldingen komen in `~/Pictures/MacAIMagic`, met de beschrijving in een bestand ernaast, niet in de afbeelding.
Een draaiend chatmodel stopt eerst. Gemeten op de M3 Max, 4 stappen met laden: 512 × 512 in 14 s en 1024 × 1024 in 42-46 s
op de GPU, ongeveer 450 beeldtokens per seconde; 512 × 512 in 78 s op de processor. FLUX staat bij de modellen
(**Kies voor afbeeldingen**) en bij **Vergelijken**, en de snelheidsmeter telt de beeldtokens terwijl het tekent. Met **Verbeteren met web** schrijft het snelle model (Snel; het zware alleen als er geen ander is)
eerst een betere Engelse beschrijving; de pagina toont elke stap met het model dat hem doet, en de statusknop bovenaan noemt elk
model dat in het geheugen staat. Het zoekt zo nodig op het web hoe iets eruitziet: met Ministral werd "het Rijksmuseum in Amsterdam bij
avondlicht" een gebouw van rode baksteen met torens en de doorgang, in 21 s, waarna het beeld 13 s kostte. Een Engelse beschrijving werkt het best: een Nederlandse
tekende een man waar de Engelse de vos tekende. De beeldengine bouw je met `scripts/build_image_engine.sh`.

## Cluster

Verbind meerdere Macs met Thunderbolt en gebruik hun geheugen samen. Op de extra Macs kies je in MacAIMagic onder
**Cluster** de rol **Helper** en druk je op **Start helper**; op de hoofd-Mac verschijnen ze vanzelf. Elke helper neemt
zoveel hele lagen als zijn GPU kan houden; de hoofd-Mac de rest, zo nodig met de expert-cache. Met een MacBook Pro
M3 Max (128 GB), een Mac Studio M5 (96 GB) en een Mac Studio M1 (32 GB) heb je samen ~256 GB: GLM-5.3-Flash Q4 past dan
helemaal in het geheugen, en van DeepSeek-V4.1-Flash Q4 staat bijna de helft van de experts van de hoofd-Mac in de cache.
Op een helper verhoogt **Verhoog GPU-limiet** wat zijn GPU mag gebruiken (bij 96 GB van ~72 naar ~88 GB). Getest op één
Mac met een lokale helper: het verdelen kost ~7% schrijfsnelheid.

## Skills en systeembeheer

Standaard aan; elk is uit te zetten onder Instellingen → **Systeembeheer**. Staan beide uit, dan krijgt het model
precies dezelfde tools en systeemprompt als voorheen.

- **Skills**: korte instructies per onderwerp, met commando's die op macOS 27 getest zijn: uiterlijk en Dock, energie,
  netwerk, software, opstartitems, opslag, beveiliging en diagnose. Het model ziet alleen de namen en laadt een skill
  als het hem nodig heeft. Eigen skills zet je in `~/Library/Application Support/MacAIMagic/Skills/<naam>/SKILL.md`.
- **Systeembeheer**: vraag bijvoorbeeld "waarom is mijn Mac traag?" of "zet het Dock links". Het model leest met vaste
  commando's die niets kunnen veranderen, en wijzigt via een plan dat jij goedkeurt: per stap de huidige waarde, de
  wijziging en hoe het terug moet. Stappen met beheerdersrechten gaan via het **wachtwoordvenster van macOS zelf** en
  vragen altijd eerst; vooraf kan de app een Time Machine-momentopname maken. Gevoelige wijzigingen worden **niet
  geblokkeerd, maar krijgen een duidelijke waarschuwing**. Vraag het model om een wijziging ongedaan te
  maken; ook dat keur je eerst goed.
- **De app kent zichzelf** (Systeembeheer → **De app**): het model leest de hulp en de stand van de app, en doet wat je
  vraagt: een model downloaden of kiezen, de engine starten, een instelling wijzigen, een scherm openen, een afbeelding
  maken, het cluster bouwen of een skill maken. Een wijziging staat eerst op een kaart; een model verwijderen vraagt altijd.

## Connectors (MCP)

Onder Instellingen → **Connectors** krijgt het model gereedschap van andere programma's en diensten, in hetzelfde
formaat als Claude Desktop (**Importeer** neemt ze daaruit en uit Claude Code over, uitgeschakeld). Klaar om aan te
zetten: **Agenda en Herinneringen** (ingebouwd, met EventKit), **Bestanden**, **Web ophalen** en **GitHub** (met een
token). Een connector op internet die om inloggen vraagt, opent je browser; het token komt in de Keychain. Het model
laadt een connector pas als het hem nodig heeft. Per connector kies je Toestaan, Eerst vragen of Weigeren; tools die
alleen lezen mogen standaard.

## Taken en heartbeat

Het model werkt ook als je er niet naast zit (**Taken** in de zijbalk, Instellingen → **Taken**):
- **Geplande taken**: een opdracht op een vast moment (eenmalig, dagelijks of op werkdagen, wekelijks of elke paar uur).
  Je maakt er een zelf, of je vraagt het in een gesprek ("geef me elke werkdag om 8 uur mijn agenda"). Elke uitvoering
  wordt een eigen gesprek, met een melding als hij klaar is of je goedkeuring nodig heeft.
- **Heartbeat** (standaard uit): het model loopt af en toe `HEARTBEAT.md` na en meldt zich alleen als er iets is.
- **Menubalk**: met taken of een heartbeat aan blijft MacAIMagic in de menubalk als je het venster sluit, en het model
  stopt. Je kunt de app ook laten starten bij inloggen.
- **Gesprekken tegelijk**: een gesprek dat op je goedkeuring wacht, houdt de andere niet op.
- **Stappenlijst**: bij een grotere klus zie je de stappen boven het invoerveld, en ze worden afgevinkt.

## Hulp

Onder **Hulp** in de zijbalk, met de **?** rechtsboven op elk scherm of met ⌘?: doorzoekbare hulp bij elk onderdeel
van de app, in het Nederlands en het Engels.

## Installeren

```sh
brew install cmake
./scripts/build_engine.sh     # llama.cpp ophalen, patchen en bouwen met Metal
./scripts/make_app.sh         # dist/MacAIMagic.app bouwen
open dist/MacAIMagic.app
```

Of gebruik de kant-en-klare build. Die is ondertekend met een Developer ID en door Apple genotariseerd, dus hij opent
zonder waarschuwing. Download de zip, pak hem uit en zet `MacAIMagic.app` in `/Applications`. Of installeer hem vanuit
Terminal:

```sh
curl -L https://github.com/mfidder2026/MacAIMagic/releases/latest/download/MacAIMagic-macOS-arm64.zip -o /tmp/MacAIMagic.zip && ditto -x -k /tmp/MacAIMagic.zip /Applications && open /Applications/MacAIMagic.app
```

Download modellen in de app (Modellen → **Download**), met `tools/download_model.sh <model-id>`, of met de hand via de
links in [`tools/models.json`](../tools/models.json). Elk model staat in een eigen map met zijn id als naam; de
vision-bestanden staan in `vision/`.

## Claude Code met het lokale model

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 claude
```

## Licenties

MacAIMagic: MIT. llama.cpp: MIT. DeepSeek-V4.1-Flash-1017 en GLM-5.3-Flash (en hun gequantiseerde bestanden): MIT. Qwen3.8-Flash-Next: Qwen-licentie.
