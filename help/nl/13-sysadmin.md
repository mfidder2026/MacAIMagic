---
title: Systeembeheer (experimenteel)
icon: gearshape.2
keywords: systeem instellen configureren macOS beheerder wachtwoord admin plan goedkeuren ongedaan snapshot waarschuwing firewall Dock slaapstand diagnose
---
Met systeembeheer vraag je het model om deze Mac te bekijken of in te stellen, in gewone taal:
- "Waarom is mijn Mac zo traag?"
- "Zet het Dock links en verberg het automatisch"
- "Zet de slaapstand van het scherm op 30 minuten"
- "Installeer VLC"

## Aanzetten
Instellingen → **Experimenteel** → **Het model mag deze Mac bekijken en instellen**. Zet je dit uit, dan werkt de app weer precies als zonder.

## Bekijken en wijzigen
- **Bekijken** (diagnose): het model leest instellingen met vaste commando's die niets kunnen veranderen. Standaard mag dat zonder te vragen.
- **Wijzigen**: het model maakt een **plan**. Je ziet elke stap, met de waarde die er nu staat. Pas na **Toestaan** voert de app het plan uit. Daarna leest de app elke waarde opnieuw, ter controle.

Beide rechten stel je in onder Instellingen → Experimenteel: **Toestaan**, **Eerst vragen** of **Weigeren**.

## Beheerdersrechten
Sommige instellingen, zoals slaapstand, DNS en firewall, hebben beheerdersrechten nodig. Zo'n plan heeft een 🔑:
- het vraagt **altijd** eerst toestemming, ook als je "altijd in dit gesprek" hebt gekozen;
- daarna vraagt **macOS zelf** om je wachtwoord. MacAIMagic en het model zien dat wachtwoord nooit;
- het vinkje **Maak eerst een lokale snapshot** maakt vooraf een Time Machine-momentopname. Standaard staat het aan.

## Waarschuwingen
Gevoelige wijzigingen worden niet geblokkeerd, maar krijgen een **rode waarschuwing** met wat ze betekenen. Bijvoorbeeld: de firewall of Gatekeeper uitzetten, FileVault, gebruikersaccounts, privacyrechten, bestanden definitief verwijderen, of een herstart. Een plan dat volgt op het lezen van het web krijgt ook een waarschuwing.

## Ongedaan maken
- Onder **Systeem → Wijzigingen door het model** staat elke wijziging, met **Ongedaan maken**.
- Of vraag het model: "maak de laatste wijziging ongedaan".
- Bij instellingen van apps (`defaults`) bewaart de app vooraf een exacte kopie. Zo kan hij ze ook terugzetten als de ongedaanmaking van het model niet klopt.
- Daarna controleert de app of alles weer is zoals ervoor, en zegt hij het als dat niet zo is.

## Wat niet kan
macOS laat sommige dingen niet via commando's regelen: privacyrechten (camera, microfoon, schermopname), FileVault aanzetten, Gatekeeper helemaal uitzetten en SIP. Het model opent dan het juiste paneel van Systeeminstellingen en zegt wat je moet aanklikken.

> Begin met diagnose: dat leest alleen en verandert niets. Kijk bij een wijziging altijd naar de kaart voordat je op Toestaan drukt.
