---
title: Werken in een map
icon: folder.badge.gearshape
keywords: werkmap map bestanden schrijven lezen uitvoeren commando rechten LSU toestaan vragen weigeren MACAIMAGIC.md geleerd
---
Geef het model een map, en het kan daar echt werken: bestanden lezen en schrijven, scripts uitvoeren, logbestanden lezen en net zo lang verbeteren tot het werkt.

## Een werkmap kiezen
Klik in de chat op **Werkmap** en kies een map. De map geldt voor dat gesprek en staat bovenin het gesprek.

## Rechten: L S U
Naast de werkmapknop staan drie letters. Per soort actie kies je **Toestaan**, **Eerst vragen** of **Weigeren**:
- **L – Lezen**: mappen bekijken en bestanden lezen (standaard: toestaan)
- **S – Schrijven**: bestanden maken en aanpassen (standaard: eerst vragen)
- **U – Uitvoeren**: commando's, scripts en apps starten (standaard: eerst vragen)

Bij "eerst vragen" verschijnt een kaart met precies wat het model wil doen. Kies **Toestaan**, **Weigeren** of **Altijd in dit gesprek**.

> Het model kan alleen binnen de werkmap schrijven. Een snelkoppeling naar buiten de map werkt niet.

## MACAIMAGIC.md: notities en wat het model leert
- Een gesprek houdt de notities zoals ze waren toen het begon. Zo hoeft het model een lang gesprek niet opnieuw te lezen als er een les bij komt. Een wijziging geldt voor nieuwe gesprekken, en voor een lopend gesprek nadat het is samengevat. Wil je dat het model iets nu meteen weet, zeg het dan in de chat.
- Zet in de werkmap een bestand **MACAIMAGIC.md** met wat het model over die map moet weten, zoals hoe je een emulator start. Het wordt bij elk bericht opnieuw gelezen.
- Na een taak van een paar stappen schrijft het model onder *Geleerd* wat werkte en wat niet, zodat het die fout niet nog eens maakt. Dat kun je uitzetten onder Instellingen → Chat → Werkmap.

## Goed om te weten
- Programma's met een venster (een emulator, een app) worden los gestart, zodat de time-out van een commando ze niet afsluit.
- Commando's kunnen geen wachtwoord vragen: `sudo` werkt hier niet. Voor instellingen waarvoor beheerdersrechten nodig zijn, is er *Systeembeheer*.

## De bestanden naast de chat
De knop **</>** naast de werkmap bovenin de chat zet rechts een paneel aan met de bestanden van de map. Een map opent met een klik; een bestand toont zijn tekst onder de lijst, alleen om te lezen. Wat het model schrijft, zie je binnen een seconde, ook in het open bestand. Een binair bestand (zoals een .prg) zegt "Geen tekstbestand", van een bestand groter dan 1 MB zie je het begin. Verborgen bestanden en .git staan er niet in. Sleep de linkerrand om het paneel breder te maken.
