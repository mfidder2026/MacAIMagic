---
title: Chatten
icon: bubble.left.and.bubble.right
keywords: gesprek vraag denken nadenken temperatuur systeemprompt context samenvatting ga door afbeelding plakken kopiëren stop schermafdruk screenshot meekijken fout foutmelding herhaald vastlopen
---
## Een vraag stellen
Typ je vraag onderin en druk op **↩** of **⌘↩**. Met **⌥↩** begin je een nieuwe regel. Het antwoord verschijnt terwijl het model schrijft; **Stop** breekt het af.

## Gesprekken beheren
- **Nieuw gesprek**: **Nieuw gesprek** bovenaan de gesprekken in de zijbalk, het potlood rechtsboven, of ⌘N. Er is geen maximum; de lijst scrolt.
- **Verwijderen**: beweeg over een gesprek en klik op de prullenbak, of selecteer het en druk op Delete (ook met een rechtermuisklik). De app vraagt eerst of je het zeker weet. Een gesprek dat bezig is, stop je eerst.

## Knoppen onder het invoerveld
| Knop | Wat het doet |
|---|---|
| Afbeelding | Voeg een afbeelding toe (ook slepen, of plakken met ⌘V). Werkt als *vision* aan staat. |
| Denken | Uit, laag, normaal of hoog: hoe lang het model eerst nadenkt (laag 2.000 tokens, normaal 8.000, hoog wat bij Instellingen staat). Werkt bij elk model dat kan nadenken. Langer is beter bij lastige vragen, maar trager. Werkt het model in stappen, dan denkt het na de eerste stap hoogstens 4.000 tokens per stap. Kies je midden in een lang gesprek een ander niveau, dan leest het model dat gesprek één keer opnieuw: bij DeepSeek staat het niveau bovenaan de prompt. |
| Web | Het model mag het web doorzoeken en pagina's lezen. |
| Werkmap | Kies een map waarin het model mag werken. |
| L S U | De rechten in die map: lezen, schrijven, uitvoeren. |

## Context en samenvatten
Bovenin het gesprek laat een meter zien hoeveel van de context het gesprek gebruikt. Bij 80% vat het model het begin samen; de berichten blijven zichtbaar, met een streep waar de samenvatting begint. Je kunt dat ook zelf meteen laten doen.

## Meekijken
Maakt het model onderweg een schermafdruk (van een programma of de C64-emulator), dan staat er een kleine versie bij die stap. Na het antwoord blijven ze in een rijtje onder **Gedachtegang** staan; klik erop voor een grotere versie.

## Als het model stopt voordat het klaar is
Lokale modellen stoppen soms halverwege. De app merkt dat en zegt het model door te gaan; je ziet dat in het gesprek. Stopt het drie keer achter elkaar, dan vraagt de app jou om "ga door" te zeggen of een aanwijzing te geven.

## Als dezelfde fout steeds terugkomt
Krijgt het model in één antwoord drie keer dezelfde foutmelding (bijvoorbeeld van een build of een script), dan zegt de app het: wat het veranderde, loste de fout niet op, dus het moet de regel uit de foutmelding letterlijk lezen en alleen die aanpassen, in plaats van steeds het hele bestand te herschrijven. Dat gebeurt opnieuw na elke volgende drie keer. Je ziet de melding als je die stap openklikt. Regelnummers tellen niet mee: een fout die een paar regels opschuift, telt als dezelfde.

Schrijft het model in één antwoord drie keer hetzelfde bestand helemaal opnieuw, zonder dat een opdracht het ondertussen draait of bouwt, dan zegt de app ook dat: bouw of draai het nu en verbeter alleen wat misgaat. Een opdracht telt als het het bestand bij naam noemt (bijvoorbeeld `./build.sh intro.asm` of `build/intro.prg`).

## Instellingen voor antwoorden
Onder **Instellingen → Chat**: denkniveau, hoe lang het model maximaal nadenkt (standaard 16.000 tokens), temperatuur (hoger is creatiever) en een eigen systeemprompt.

> Algemene notities die het model in elk gesprek moet kennen, zet je in MACAIMAGIC.md: Instellingen → Chat → **Open bestand**.

Gesprekken worden op deze Mac bewaard. Verwijder een gesprek met de rechtermuisknop in de zijbalk.
