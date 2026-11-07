---
title: Agent: e-mail, browser, apps en spraak
icon: wand.and.stars
keywords: agent e-mail mail concept versturen browser website surfen formulier klikken apps besturen toegankelijkheid spraak microfoon inspreken voorlezen stem spraakbericht
---
Onder **Instellingen → Agent** laat je het model ook buiten de chat werken. Alles staat standaard uit, en elke wijziging komt eerst op een kaart.

## E-mail
Zet **E-mail via de Mail-app** aan. Het model werkt met de accounts die al in de Mail-app staan; MacAIMagic krijgt geen wachtwoord.
- **Lezen, zoeken en samenvatten** gebeurt zonder te vragen. Bijvoorbeeld: "Wat is er vandaag binnengekomen?" of "Zoek de factuur van de garage".
- **Een concept** opent in Mail nadat je de kaart hebt goedgekeurd. Je verstuurt het zelf.
- **Versturen** vraagt altijd, ook als je eerder "Altijd in dit gesprek" koos. Kijk de ontvangers en de tekst na.
- De eerste keer vraagt macOS of MacAIMagic Mail mag bedienen. Heb je dat geweigerd, zet het dan aan in Systeeminstellingen → Privacy en beveiliging → Automatisering.

Tekst in een e-mail is voor het model informatie, geen opdracht.

## Browser
Zet **Browser in een eigen venster** aan. Het model opent pagina's in een eigen venster van MacAIMagic, zodat je kunt meekijken. Dat venster heeft eigen cookies, los van Safari en Chrome.
- Het model leest de pagina als tekst, met genummerde links, knoppen en velden.
- Een **link** volgen en in een **zoekveld typen** gebeuren zonder vragen.
- Een **knop** vraagt eerst toestemming.
- Een knop die iets **verstuurt, koopt, plaatst of verwijdert** vraagt elke keer, met een waarschuwing. Dat geldt ook voor het versturen van een formulier.
- **Inloggen doe je zelf** in het browservenster.
- **Wachtwoorden, pincodes en betaalgegevens** vult het model nooit in.

## Apps besturen
Zet **Het model mag deze apps besturen** aan en voeg met **App toevoegen…** de apps toe die het mag gebruiken, bijvoorbeeld Teksteditor of Notities. macOS vraagt de eerste keer om toegang onder Toegankelijkheid.
- Het model ziet in het venster van die app de knoppen, velden en menu's, met nummers. Het maakt geen schermafbeelding, dus het werkt ook met een model zonder beeld.
- Elke klik, elke tekst en elke toets komt op een kaart.
- Een knop die iets verstuurt of verwijdert, en de Return-toets, vragen elke keer.
- **Nooit toegestaan**:
  - wachtwoordvelden;
  - Sleutelhanger, Wachtwoorden, Systeeminstellingen, Terminal en wachtwoordmanagers;
  - een app afsluiten met ⌘Q.

## Spraak
Zet **Spraak** aan.
- **Inspreken**: druk op de microfoon naast het invoerveld en spreek je vraag in. Druk nog eens om te stoppen. De herkenning gebeurt op deze Mac. macOS vraagt de eerste keer om de microfoon en om spraakherkenning.
- **Voorlezen**: de luidspreker onder een antwoord leest het voor. Met **Lees antwoorden vanzelf voor** gebeurt dat na elk antwoord in het venster.
- **Stem**: kies een stem in de taal van de app. Betere stemmen download je in Systeeminstellingen → Toegankelijkheid → Gesproken materiaal.
- **Telegram**: een spraakbericht aan je bot wordt op de Mac tekst. De bot laat zien wat hij verstond ("🎙 …") en het model antwoordt daarop.
