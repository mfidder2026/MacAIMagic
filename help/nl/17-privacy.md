---
title: Privacy en veiligheid
icon: lock.shield
keywords: privacy veiligheid lokaal cloud gegevens wachtwoord prompt-injectie
---
- **Alles lokaal**: het model draait op deze Mac. Je gesprekken, bestanden en documenten gaan niet naar een AI-dienst.
- **Wat wel naar internet gaat**: zoekvragen en webpagina's (alleen als **Web** aan staat), het downloaden van modellen, en wat jij zelf deelt met **Deel op GitHub**.
- **Rechten**: in een werkmap, en bij systeembeheer, bepaal jij wat het model zonder te vragen mag.
- **Wachtwoorden**: de app vraagt nooit om je wachtwoord. Is het nodig, dan vraagt macOS er zelf om.
- **Prompt-injectie**: een webpagina of bestand kan tekst bevatten die het model probeert te sturen. Daarom keur je wijzigingen zelf goed, en geeft de app een waarschuwing als een plan volgt op het lezen van het web.
- **Connectors**: een connector op internet stuurt wat het model meegeeft naar die dienst; een connector op deze Mac niet. Tokens staan in de Keychain.
- **Taken**: een taak of heartbeat werkt met dezelfde rechten als een gesprek. Een wijziging wacht altijd op jouw goedkeuring, ook als je er niet bij bent.
- **Telegram**: je berichten en de antwoorden gaan via de servers van Telegram, niet versleuteld van begin tot eind. Alleen gekoppelde accounts krijgen antwoord; de token staat in de Keychain. Het model en je bestanden blijven op de Mac.
- **Agent**: e-mail, de browser, apps en spraak staan standaard uit. Mail blijft in de Mail-app; het browservenster heeft eigen cookies; spraak wordt op deze Mac tekst. Versturen, kopen en verwijderen vragen elke keer.
- **Netwerk**: de API en cluster-helpers luisteren standaard alleen op deze Mac of op de Thunderbolt-kabel.
