---
title: Telegram
icon: paperplane
keywords: telegram bot botfather pair pairing code phone away message messages button buttons approve notification token
---
With Telegram you talk with the model on this Mac when you are not at it, from your phone or another computer. The model stays on the Mac; Telegram only carries the messages.

## Setting up
1. Open Telegram, find **@BotFather** and send **/newbot**. Choose a name and a username that ends in `bot`.
2. BotFather gives you a **token**. Paste it in MacAIMagic under **Settings → Telegram → Bot** and click **Save**. The token goes into your Keychain, not into a file.
3. Switch **Telegram** on. The status then says "Connected as @yourbot".
4. Click **Pair an account**. You get a 6-digit code. Send that code to your bot in a private chat within 10 minutes. The bot answers "Paired".

Only paired accounts get an answer. Messages from anyone else get no reaction, so they cannot even tell the bot is there. Under **Who may talk** you unpair an account again.

## Talking
- Each paired account has one conversation that goes on: "✈︎ Telegram · name". It is also in the sidebar on the Mac, so you can read on there.
- The answer grows in Telegram while the model writes. A long answer comes in several messages.
- **/new** (or /nieuw) starts a new conversation.
- **/stop** stops the answer.
- **/status** says whether the model is loaded, what is running and what the next task is.
- If the model is not loaded, it loads for your question. The bot says "Loading the model…"; with a large model that takes a few minutes. After that the model stays loaded.
- **Photos** go to the model when Look at images is on.
- **Text files** up to 1 MB are read along with your message.
- **Voice messages** cannot be read yet.

## Approving
When the model wants to change something, such as writing a file, running a command or using a connector with write rights, Telegram shows a card with **Allow**, **Deny** and **Always in this conversation**. The same rights apply as in the chat on the Mac.
- Only the account of that conversation can press the buttons.
- No answer within a day counts as no.
- **Administrator rights** are never approved through Telegram. The bot tells you to do it on the Mac, and you get a notification there.

## Tasks and heartbeat
With **Tasks and heartbeat to Telegram too** on, these also go to the account you paired first:
- a task that finished or stopped;
- what the heartbeat found;
- an approval a task needs (with buttons).

With Telegram on, MacAIMagic stays in the menu bar when you close the window, so the bot keeps answering. While the Mac sleeps, messages wait until it wakes; Telegram keeps them for up to a day.

## Privacy
Your messages and the answers go through Telegram's servers. They are not end-to-end encrypted there, because a bot cannot use a secret chat. So send nothing through Telegram that you would not trust Telegram with. The model itself, your files and your settings stay on the Mac. The Mac calls out to Telegram itself; nothing is open to the internet.

## Problems
- **"Telegram does not know this token"**: the token is wrong or was revoked. Remove it, make a new one at BotFather (**/token**) and paste that.
- **"Another program already uses this bot"**: only one program at a time can read a bot. Stop the other one, or make a separate bot for MacAIMagic.
- **No answer**: check that Telegram is on, that the status says "Connected" and that your account is under Who may talk. The log at the bottom shows what happened.
