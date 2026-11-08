---
title: Troubleshooting
icon: wrench.and.screwdriver
keywords: problem error not working slow does not start stuck memory download failed quarantine password
---
## The engine does not start
- Open **System** and see what is orange; there is usually a button next to it.
- Close large programs: a compact model needs 110–120 GB.
- Choose a smaller model, or one whose card says it "fits".

## Writing is slow
- Look under **Live** whether a lot is read from the SSD. Then the model does not fit whole: choose a compact model or raise the GPU limit.
- Set **Think** to low or off for simple questions.
- A long context makes prompt reading slower. Start a new conversation, or have this one summarized.

## The model stops halfway or repeats itself
Say "go on", or give a hint. For work in a folder, a short note in MACAIMAGIC.md helps.

## A download fails
Press **Download** again: it carries on where it was. If the card says a file has changed, use **Check for update**.

## A system change did not work
- Afterwards the model says which step failed; the steps in the conversation show it too.
- Ask the model to undo the change: the steps that did run are put back.
- If you cancelled the password dialog, nothing was changed.

## The password dialog does not appear
It can be behind the MacAIMagic window. Look in the Dock, or press ⌘⇥.

## Still stuck?
Use **Compare → Export measurement**, or look in `~/Library/Application Support/MacAIMagic/engine.log`.
