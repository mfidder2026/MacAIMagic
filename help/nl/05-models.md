---
title: Modellen
icon: square.stack.3d.up
keywords: model downloaden compact Q4 MTP geheugen SSD GPU-limiet update verwijderen snel zwaar afbeeldingen modelmap
---
## Welk model?
Elke kaart zegt voor deze Mac of het model **helemaal in het geheugen past**, **van de SSD streamt** (trager) of **te groot** is. **Systeem** raadt het beste model aan dat helemaal past.

| Soort | Kenmerk |
|---|---|
| **Compact** | Alles wat een token nodig heeft staat in het geheugen. De snelle keuze. |
| **Q4** | Dichter bij de originele gewichten, maar groter dan 128 GB: de meest gebruikte experts staan op de GPU, de rest komt van de SSD. |
| **MTP** | GLM en Qwen raden de volgende tokens vooraf; dezelfde antwoorden, tot 65% sneller schrijven. Aan/uit onder Instellingen → Engine. |

## Knoppen op een kaart
- **Download**: gaat verder na een onderbreking, en elk bestand wordt gecontroleerd (sha256).
- **Controleer op update**: kijkt in een paar seconden of er een nieuwere versie is, zonder het hele model te lezen.
- **Start** / **Stop**: laadt het model in de engine.
- **Snel** / **Zwaar**: welk model Documenten gebruikt voor klein werk en voor het schrijven.
- **Kies voor afbeeldingen**: het model voor Beeld.
- **Verwijder model**: maakt de schijfruimte vrij (stop het model eerst).

## Meer geheugen voor de GPU
**Verhoog GPU-limiet** laat de GPU meer geheugen vastleggen. Dat vraagt je wachtwoord en geldt tot de volgende herstart.

## Modelmap
Standaard staan de modellen in `~/Library/Application Support/MacAIMagic/models`. Een andere map, zoals een externe SSD, kies je onder Modellen → Modelmap → **Kies map…**.
