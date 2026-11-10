---
title: Settings
icon: gearshape
keywords: settings memory keep conversation language preferences context vision MTP port address system management skills tasks heartbeat menu bar login repeated text ngram
---
Open the settings with **⌘,**.

## Chat
- **Language**: Dutch, English, German or French. The model gets its instructions in the same language. The help is in Dutch and English.
- **Answers**: reasoning effort, maximum thinking, temperature, system prompt, and general notes (MACAIMAGIC.md).
- **Work folder**: working in a folder on/off, keeping what the model learns, and the rights R W X.
- **Web search**: your own Brave Search key.

## Engine
- **Context**: from 32K to 1M tokens. More context takes more memory.
- **Images (vision)**, **MTP**, **Write repeated text faster** (with MTP: text already in the conversation, such as code the model changes, in large pieces at once), **Start engine when the app opens**, **Moving background**.
- **Keep conversations in the engine** (on by default): what the engine has read of a conversation goes to the SSD as soon as another conversation, a task or Documents gets the model, and when the engine stops. When you go on later, also after a restart, the model does not read that conversation again. With a large model that saves minutes. A long conversation takes a few hundred MB to about a GB. It takes at most 40 GB (and never more than a tenth of the free disk); the oldest go first, and a deleted conversation takes its own along. **Clear** frees the space at once.
- **Server**: address, port and API key (see *Local API*).

## Connectors
Tools from other programs and services, with rights per connector (see *Connectors*).

## System management
**Skills** and **This Mac**: whether the model may look at and set up this Mac, and the rights to read and to change the system. They are on by default.

## Tasks
The **heartbeat** (on or off, how often, between which hours, and whether the model may load for it), **In the background** (stay in the menu bar, stop the model when the window closes, start at login) and whether the model stops again after a task (see *Tasks and heartbeat*).
