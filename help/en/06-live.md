---
title: Live dashboard
icon: waveform.path.ecg
keywords: speed tokens per second GPU CPU memory SSD chart gauge
---
**Live** shows what the Mac does while the model works:
- the **speed gauge**: tokens per second while writing;
- charts of **GPU** and **CPU**, **memory**, and what is read from the **SSD**;
- a mini version at the bottom of the sidebar; click it to open Live.

## Two speeds
- **Writing** (decode): how fast the answer appears.
- **Prompt reading** (prefill): how fast the model reads your question, attachments and web pages. On long tasks this is often the bottleneck.

> If the model reads a lot from the SSD, it does not fit whole. Choose a compact model, or raise the GPU limit (see *Models*).

While the engine runs, the Mac stays awake (the display may still sleep).
