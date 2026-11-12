---
title: Modellen
icon: square.stack.3d.up
keywords: model klein Ling Ministral downloaden compact Q4 MTP geheugen SSD GPU-limiet update verwijderen snel zwaar afbeeldingen modelmap herhaalde tekst ngram
---
## Welk model?
Elke kaart zegt voor deze Mac of het model **helemaal in het geheugen past**, **van de SSD streamt** (trager) of **te groot** is. **Systeem** raadt het beste model aan dat helemaal past.

| Soort | Kenmerk |
|---|---|
| **Compact** | Alles wat een token nodig heeft staat in het geheugen. De snelle keuze. |
| **Q4** | Dichter bij de originele gewichten, maar groter dan 128 GB: de meest gebruikte experts staan op de GPU, de rest komt van de SSD. |
| **MTP** | GLM en Qwen raden de volgende tokens vooraf; dezelfde antwoorden, tot 65% sneller schrijven. Aan/uit onder Instellingen → Engine. Daaronder **Herhaalde tekst sneller schrijven**: code aanpassen gaat er tot twee keer zo snel mee. |

**Om te programmeren** is er **Qwen3.8-27B**: een dicht model van 27B dat bij elk woord al zijn gewichten gebruikt. Het is sterk in code, past met 18 GB al op een Mac met 32 GB, en leest afbeeldingen. Het schrijft wel langzamer dan Qwen3.6-35B-A3B, dat maar 3B per woord gebruikt; daarom wordt het nooit vanzelf aangeraden.

**Voor een Mac met 8 of 16 GB** zijn er twee kleine modellen. **Ministral-3-8B** leest ook afbeeldingen en wordt aangeraden op 16 GB. **Ling-3.0-tiny** gebruikt maar 1B van zijn 8B per woord en is daardoor drie keer zo snel, maar leest geen afbeeldingen. Het wordt aangeraden op 8 GB, waar macOS het grootste deel in het geheugen houdt en de rest van de SSD leest.

## Knoppen op een kaart
- **Download**: gaat verder na een onderbreking, en elk bestand wordt gecontroleerd (sha256).
- **Controleer op update**: kijkt in een paar seconden of er een nieuwere versie is, zonder het hele model te lezen.
- **Start** / **Stop**: laadt het model in de engine, of haalt het eruit. Tijdens het laden en het ontladen loopt een ronde meter met een percentage, in de status bovenaan en in de chat; hij rekent met hoe lang het die keer ervoor duurde.
- **Snel** / **Zwaar**: welk model Documenten gebruikt voor klein werk en voor het schrijven.
- **Kies voor afbeeldingen**: het model voor Beeld.
- **Verwijder model**: maakt de schijfruimte vrij (stop het model eerst).

## Meer geheugen voor de GPU
**Verhoog GPU-limiet** laat de GPU meer geheugen vastleggen. Dat vraagt je wachtwoord en geldt tot de volgende herstart.

## Modelmap
Standaard staan de modellen in `~/Library/Application Support/MacAIMagic/models`. Een andere map, zoals een externe SSD, kies je onder Modellen → Modelmap → **Kies map…**.
