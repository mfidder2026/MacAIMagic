---
title: Agent: mail, browser, apps and speech
icon: wand.and.stars
keywords: agent mail email draft send browser website browse form click apps control accessibility speech microphone dictate read aloud voice voice message
---
Under **Settings → Agent** you let the model work outside the chat too. Everything is off by default, and every change comes on a card first.

## Mail
Switch on **Mail through the Mail app**. The model works with the accounts already in the Mail app; MacAIMagic gets no password.
- **Reading, searching and summarizing** happen without asking. For example: "What came in today?" or "Find the invoice from the garage".
- **A draft** opens in Mail after you approve the card. You send it yourself.
- **Sending** always asks, also if you chose "Always in this conversation" before. Check the recipients and the text.
- The first time, macOS asks whether MacAIMagic may control Mail. If you said no, switch it on in System Settings → Privacy & Security → Automation.

Text in a mail is information for the model, not an instruction.

## Browser
Switch on **Browser in a window of its own**. The model opens pages in a window of MacAIMagic's own, so you can watch. That window has its own cookies, apart from Safari and Chrome.
- The model reads the page as text, with numbered links, buttons and fields.
- Following a **link** and typing in a **search field** happen without asking.
- A **button** asks first.
- A button that **sends, buys, posts or deletes** asks every time, with a warning. So does sending a form.
- **You log in yourself** in the browser window.
- The model never fills in **passwords, PINs or payment details**.

## Controlling apps
Switch on **The model may control these apps** and add the apps it may use with **Add app…**, for example TextEdit or Notes. The first time, macOS asks for access under Accessibility.
- In that app's window the model sees the buttons, fields and menus, with numbers. It takes no screenshot, so it also works with a model without vision.
- Every click, every text and every key comes on a card.
- A button that sends or deletes something, and the Return key, ask every time.
- **Never allowed**:
  - password fields;
  - Keychain Access, Passwords, System Settings, Terminal and password managers;
  - quitting an app with ⌘Q.

## Speech
Switch on **Speech**.
- **Dictate**: press the microphone next to the input field and speak your question. After two seconds of silence your question goes by itself; if the model is not loaded, it loads first. If the microphone does not work, switch on Dictation in System Settings → Keyboard → Dictation. Recognition happens on this Mac. The first time, macOS asks for the microphone and for speech recognition.
- **Read aloud**: the speaker under an answer reads it aloud. With **Read answers aloud by themselves** that happens after every answer in the window.
- **Voice**: choose a voice in the app's language. Better voices can be downloaded in System Settings → Accessibility → Spoken Content.
- **Telegram**: a voice message to your bot becomes text on the Mac. The bot shows what it heard ("🎙 …") and the model answers that.
