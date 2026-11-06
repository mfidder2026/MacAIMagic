---
title: Live dashboard
icon: waveform.path.ecg
keywords: snelheid tokens per seconde GPU CPU geheugen SSD grafiek meter
---
**Live** laat zien wat de Mac doet terwijl het model werkt:
- de **snelheidsmeter**: tokens per seconde tijdens het schrijven;
- grafieken van **GPU** en **CPU**, het **geheugen** en wat er van de **SSD** wordt gelezen;
- onderin de zijbalk een mini-versie; klik erop om Live te openen.

## Twee snelheden
- **Schrijven** (decode): hoe snel het antwoord verschijnt.
- **Prompt lezen** (prefill): hoe snel het model je vraag, de bijlagen en de webpagina's leest. Bij lange taken is dit vaak de bottleneck.

> Leest het model veel van de SSD, dan past het model niet helemaal. Kies dan een compact model, of verhoog de GPU-limiet (zie *Modellen*).

Terwijl de engine draait, blijft de Mac wakker (het scherm mag wel uit).
