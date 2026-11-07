---
title: Connectors
icon: puzzlepiece.extension
keywords: connectors MCP gereedschap agenda herinneringen GitHub bestanden web ophalen importeren Claude Desktop inloggen OAuth token
---
Een **connector** geeft het model gereedschap van een ander programma of een dienst, via het Model Context Protocol (MCP). Bijvoorbeeld je agenda, GitHub of bestanden buiten de werkmap.

## Een connector toevoegen
Open Instellingen → **Connectors**.
- **Voorbeeld toevoegen** biedt connectors die meteen werken:

| Voorbeeld | Wat het doet | Nodig |
|---|---|---|
| Agenda en Herinneringen | afspraken en herinneringen tonen, maken en afvinken | niets: ingebouwd in de app |
| Bestanden | lezen, zoeken en schrijven in Documenten, Downloads en Bureaublad | `npx` (brew install node) |
| Web ophalen | een webpagina als tekst ophalen | `uvx` (brew install uv) |
| GitHub | repositories, issues en pull requests | een persoonlijk token van GitHub |

- **Toevoegen…** voor je eigen connector: een *programma op deze Mac* (commando en argumenten, zoals bij Claude Desktop) of een *internetadres*.
- **Importeer** neemt connectors over uit Claude Desktop en Claude Code. Ze komen uitgeschakeld binnen, zodat je eerst kunt kijken.
- **Test verbinding** start de connector even en laat zien welke tools hij heeft.

## Zo gebruikt het model ze
Het model ziet alleen de namen van de connectors die aan staan. Pas als het er een nodig heeft, laadt het de tools ervan ("Connector laden: GitHub"). Die blijven daarna in dat gesprek. Zo blijft de prompt kort en het model snel. Een connector met **Altijd geladen** is er in elk gesprek.

## Rechten
Per connector kies je **Toestaan**, **Eerst vragen** of **Weigeren**.
- Een tool die zegt dat hij alleen leest, mag standaard (behalve bij Weigeren).
- Andere tools vragen eerst. De kaart toont de connector, de tool en precies wat er wordt meegegeven.
- Een rode waarschuwing staat erbij als een tool iets kan verwijderen, als de connector op internet staat, of als de aanroep volgt op het lezen van het web.

## Inloggen bij een dienst
Vraagt een connector op internet om in te loggen, dan opent de app de inlogpagina in je eigen browser. Daarna gaat het vanzelf verder. Het token komt in de Keychain; MacAIMagic ziet je wachtwoord niet. **Uitloggen** staat in het menu van de connector. Voor een dienst zonder inlogpagina (zoals GitHub) vul je een token in; ook dat komt in de Keychain.

## Agenda en Herinneringen
De eerste keer vraagt macOS of MacAIMagic bij je agenda en herinneringen mag. Dat kun je later wijzigen onder Systeeminstellingen → Privacy en beveiliging.

> Een connector op internet stuurt wat het model meegeeft naar die dienst. Kijk bij Eerst vragen goed naar de kaart.

## Iets werkt niet
Open in het menu van de connector **Log**: daar staat wat het programma of de dienst meldde. Ontbreekt `npx` of `uvx`, dan zegt de app hoe je het installeert.
