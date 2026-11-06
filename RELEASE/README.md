# MacAIMagic 1.10.0 (macOS, Apple Silicon)

`MacAIMagic-1.10.0-macOS-arm64.zip` contains the app with the engine built in (llama.cpp with Metal and the
MacAIMagic patches). The models are **not** included: see [Installation](../README.md#installation) for how to download them.

1. Unzip the download and move `MacAIMagic.app` to `/Applications`. The build is signed with a Developer ID and notarized by Apple, so it opens without a warning. Or install from Terminal:
   ```sh
   curl -L https://github.com/mfidder2026/MacAIMagic/releases/latest/download/MacAIMagic-macOS-arm64.zip -o /tmp/MacAIMagic.zip && ditto -x -k /tmp/MacAIMagic.zip /Applications && open /Applications/MacAIMagic.app
   ```
2. Open **Modellen**, download a model (or choose the folder that holds your models under Modelmap → **Kies map…**), then press **Start**.

Check the download: `shasum -a 256 -c MacAIMagic-1.10.0-macOS-arm64.zip.sha256`

Runs on every Apple Silicon Mac (M1 and later) with macOS 14 or later. Every model runs: what does not fit in memory streams from the SSD, and the app recommends the one that fits (32 GB: Qwen3.6-35B-A3B, 8 or 16 GB: Ministral-3-8B). As a cluster helper any amount of memory helps.

New in 1.10.0:
- **The model sets up this Mac for you** (Settings → Systeembeheer, on by default). Ask "why is my Mac slow?" and it only reads, with fixed commands that cannot change anything. Ask "put the Dock on the left" and it makes a **plan**: a card shows every step with the value it has now, and nothing happens until you press **Toestaan**. Afterwards the app reads every value again as a check. Steps that need administrator rights go through **macOS's own password dialog** (the model never sees your password), always ask first, and can make a Time Machine snapshot beforehand. Sensitive changes (firewall, Gatekeeper, FileVault, user accounts, deleting for good, a restart) are not blocked but get a **red warning**, and so does a plan that follows reading the web.
- **Undo by asking.** Say "undo the last change": the model puts it back through the same kind of card, and the app checks that every value is as before. For app settings the app keeps an exact copy first, so undo works even when the model's own undo is wrong.
- **Skills**: eight built-in guides with commands tested on macOS 27 (appearance and Dock, energy, network, software, startup items, storage, security, diagnosis). The model loads one only when it needs it. Add your own under Settings → Systeembeheer → Open map.
- **Help for the whole app** (sidebar → Hulp, the **?** at the top right of every page, or ⌘?): 18 searchable topics in Dutch and English.
- **New model: Qwen3.6-35B-A3B Heretic Q4** (21 GB), Qwen3.6 without refusals. It fits a Mac with 32 GB; measured in the app on an M3 Max: 78–80 tok/s writing.
- After a complete answer that only read the system or the web, the app no longer tells the model to go on once more.

New in 1.9.13:
- **"Controleer" no longer makes the Mac hang.** In 1.9.12 it read every file of a model to check it, hundreds of GB at once. It is replaced by **Controleer op update**, which reads no file and takes a few seconds: it compares the files on your Mac with this version of MacAIMagic and asks the server whether there is anything new. An update starts at once; otherwise the card says "Geen update beschikbaar".
- **One clear button per model:** Download when a model is not on your Mac, Controleer op update when it is, Update when an update is known.
- When the maker has published newer files than this version uses, the card says so and downloads nothing: the app runs the version it was tested with, and a next version takes the new files over.

New in 1.9.12:
- **Delete a model** with the trash button on its card, after a question. Not while it downloads or runs.
- **Updates of a model are recognised.** Each verified file now records its checksum. When the catalog names another version, the card shows **Update**, which downloads only the files that differ; the version you have keeps working until then.
- **Controleer** checks once which version of a model is on your Mac, for models downloaded before this version. It reads the files (a few minutes for a large model) and downloads nothing.
- **Exporteer meting** and **Deel op GitHub** on Compare: save your measurement as one file, without names or folders, and share it through a form on GitHub. Measurements of Macs with 8, 16 or 24 GB help most.
- When the chat's model runs only as the fast model, the chat says so; starting it stops the fast copy first, so it is never in memory twice.

New in 1.9.11:
- **Better images with "Verbeteren met web".** The description for the image model is now always English, starts with the subject's name and holds only what can be seen: no measurements, history or invented details, which the image model would draw. A request like "maak een foto van de eifeltoren" now gives the real Eiffel Tower; before, a long Dutch description drew a tower that does not exist.
- **A real building is looked up first.** When the model searches but reads no page, the app reads a page with text and an encyclopedia (not a stock-photo site) and has the description rewritten from them. Lesser-known buildings still come out as a close likeness rather than the real thing.

New in 1.9.10:
- **The fast model writes the image description.** With "Verbeteren met web" on, the fast model (Snel, for example Ministral) writes the better description; it loads in seconds and stays beside the image. The heavy model only does it when there is no other. Before, it started the heavy model, which takes minutes and then had to stop again.
- **The status pill names every model in memory**, with its role: for example "DeepSeek-V4.1-Flash actief (Zwaar) · Ministral-3-8B laden… (Snel) · FLUX.2 tekent". With nothing loaded it says "Geen model geladen".
- **Beeld shows who does what**: which model writes the description and which draws, and every step with its model, also a model that stops to make room.
- The speed gauge counts the fast model's writing too.

New in 1.9.9:
- **Choose every model the same way.** Each model card has role buttons in one style: **Zwaar** and **Snel** for a model that chats, **Afbeeldingen** for one that draws. You now choose the fast model for Documents yourself; choosing it again lets the app pick.
- **Documents shows all three.** The sidebar lists the heavy, the fast and the image model in the same rows, each with a dot that is green while it runs, and Start / Stop where it applies.

New in 1.9.8:
- **FLUX stands among the models.** Choose it under Modellen with **Kies voor afbeeldingen**, apart from the chat model. Compare measures it too: the same 1024 × 1024 image on every Mac (46 s on an M3 Max).
- **The speed gauge counts image tokens** while an image is drawn (about 450 per second on an M3 Max), and its scale grows with them.
- **Verbeteren met web** on the Beeld page: the chat model first writes a better English description and looks up on the web what something looks like, then the image is made. With Ministral, "het Rijksmuseum in Amsterdam bij avondlicht" became the real red-brick building with its towers. What goes to the search engine is cleaned of e-mail addresses, numbers and amounts.
- **Faster images on a Mac with room:** the last step works in parts only where memory is short. On an M3 Max 1024 × 1024 now takes 42-46 s instead of 61 s; a Mac with 8 or 16 GB still works in parts where it must.

New in 1.9.7:
- **Make images on the Mac** (sidebar → Beeld) with FLUX.2 Klein 4B (5.3 GB). Measured on an M3 Max: 512 × 512 in 16-20 s, 1024 × 1024 in 60 s on the GPU. A description in English works best. Images go to Pictures/MacAIMagic, with the description in a file beside them, not inside the image.
- **Ministral-3-8B** (5 GB), a small model that also reads images, for a Mac with 8 or 16 GB: 51 tok/s on the M3 Max.
- **Downloads work again.** The makers replaced or removed files of Qwen3.8-Flash-Next and DeepSeek-V4.1-Flash Compact, so these could no longer be downloaded. Every download now names one version of its files, models you already have stay valid, and a replaced file is reported at once, before anything comes down. Download errors now show on the model card.
- **Fixes:** a command that starts a program in the background no longer waits for it, and Stop and the time-out end the whole command; the pause after the last step shows in the chat; a failing Brave search says so and DuckDuckGo takes over; the search region follows the app's language; an unreadable conversations file is kept as .bad; the API key is no longer visible in the process list; a cluster helper stops with the app, and one added by hand that does not answer is left out.
- The Documents button reads "Document voorbereiden", and the version stands beside the name in the sidebar.

New in 1.9.6: a Mac with 16 GB can use Qwen3.6-35B-A3B. It no longer says "too big": the model streams from the SSD with a small expert cache, and the system check recommends it. This has not yet been measured on a real Mac with 16 GB and may be slow.

New in 1.9.5: the content of the window no longer slides off the screen while a document is written. Steps and remarks now scroll in a space of their own, so the buttons stay within reach.

New in 1.9.4:
- **The app no longer locks up while a document is written.** The text reached the screen from another thread, and the two waited for each other. The speed gauge now counts this writing too.
- **Searching keeps working.** DuckDuckGo refuses after a few quick searches, and the app took that for "no results". It now searches more calmly, goes to Bing when refused, and says at once when nothing from the web is used.
- **Engines left behind by a forced quit are stopped** at the next start.

New in 1.9.3: the documents module shows what the fast model is doing (starts by itself, loading, running), has a button to start or stop it, and says why when it does not start. A model that failed is no longer tried again for every page. The number in the speed gauge stands in the middle of its ring.

New in 1.9.2:
- **Thinking off now works on GLM.** Its template ignored the setting and always started thinking, so a document stopped with "the model gave no text", and in a chat GLM kept thinking with Think off. Summaries and lessons in a chat had the same problem.
- **One silent section no longer stops a document.** It stays as it was and the app says so; the other sections are written.
- **The window's buttons no longer stand over the name at the top of the sidebar.**
- **A long structure is no longer cut off**, and a heading above all others becomes the document's title instead of its first chapter.

New in 1.9.1:
- **Projects.** A project holds attachments, one house style and its documents. What the cover needs is entered once, and a value found in one document is known for the next.
- **Attachments first, house style last.** Say "make an AQS": the model looks in the attachments for what the document must consist of, searches the web only for what they do not say, and the house style is applied to the finished draft as layout only. A single question gets a short structure of its own.
- **The house style keeps its own name**, and the input field and buttons are larger and easier to read.
- The client's details stay off the search engine, and each page is judged against the search question that found it.

New in 1.9:
- **Documents without cloud AI** (sidebar → Documenten). A project is a folder with its house style in `huisstijl.docx`. All text is changed in a Markdown draft, and the Word file comes last, in that house style: cover, headers and footers, numbered headings, table look and table of contents come from your own template.
- **A question is researched first.** The app searches the web, reads up to 8 pages and writes a draft with numbered sources. The Word file follows when you approve it. E-mail addresses, bank and phone numbers and amounts are taken out of what goes to the search engine; the rest of your text stays on the Mac.
- **Two models.** A fast model does the small work (search questions, notes, spelling), a heavy one the writing. Measured on an M3 Max with 128 GB: Qwen3.6 71 tok/s next to Qwen3.8 at 31 tok/s, a researched question in about 90 seconds, a template with 8 sections in about 75. On a Mac where two do not fit, one model does everything.

New in 1.8.3:
- **Every new chat starts in your work folder.** A new chat could lack the folder, for example after you deleted the last one. The model then had no tools and said it could not work on this Mac.
- **The Werkmap button tells the truth.** It is on only when this chat really has a folder; off means the model cannot use files or commands here.
- **The model looks outside the work folder too.** It now knows it can search and read anywhere on the Mac with `run_command` and start installed programs, such as VICE in Applications. Writing outside the folder it does only when you ask.

New in 1.8.2:
- **A task ends only when the model says so.** After steps, a remark like "this does not work well" no longer ends the task: the model goes on until it starts its message with DONE or asks you something. If it keeps stopping, the app says so. It also knows that `sudo` and `dtruss` do not work here, and that a command without output calls for another approach.
- **The system check shows the version and the place of the running app**, because an older copy on the Mac is easily started by accident.

New in 1.8.1:
- **The model learns from its mistakes.** A work folder gets a `MACAIMAGIC.md` when it has none. After a task of a few steps the model says what it established (commands and paths that worked, what failed and why), and the app puts that under *Geleerd*; every next message in that folder reads it. You can edit the file yourself, and turn this off in Settings. It is skipped after a task that read the web, and when writing is denied in the rights matrix.
- **Long tasks stay readable.** The steps of an answer are folded ("37 steps"), with the latest two visible while it works. An automatic follow-up no longer repeats the whole list.

New in 1.8:
- **The model works until the task is done.** When it ends its turn without finishing (it announces a step and stops, only thinks, or leaves a tool call behind in its thinking), the app tells it to go on, and shows that in the chat. A cut-off answer goes on too, a long task with a single question is summarized when the context fills up, and the model is told when Python and git are not on the Mac.
- **Models larger than memory stream on every Mac.** On 32 GB they no longer say "too big" and now run with a real expert cache instead of slow page faults. Measured with 32 GB of memory left on an M3 Max: DeepSeek-V4.1-Flash Compact ~5 tok/s, Qwen3.8-Flash-Next 2–6, GLM-5.3-Flash Compact ~2.6, DeepSeek-V4.1-Flash Q4 ~1.5, GLM-5.3-Flash Q4 ~0.1. Each model card shows this on a small Mac.

New in 1.7.1: the app is signed with a Developer ID and notarized by Apple, so macOS no longer blocks a browser download.

New in 1.7: MacAIMagic works out the Mac it runs on. A system check at every start (sidebar → Systeem) checks the engine, the download tools, the models, disk space, the GPU limit and Apple's developer tools, fixes what it can and offers the rest with one button. It recommends the best model that fits in this Mac's memory, and on a Mac with little memory it shrinks the context and turns vision off when needed. New model: Qwen3.6-35B-A3B Q4 (22 GB), which fits a Mac with 32 GB. Model downloads no longer need Python (a clean Mac asked for the developer tools).

New in 1.6.2: the engine starts on every Mac. It used Homebrew's OpenSSL from the build Mac, so on a Mac without it the engine did not start; it now uses only what comes with macOS. Every binary is signed with the hardened runtime, ready for notarization by Apple.

New in 1.6.1: a limit on thinking (Settings → Maximaal nadenken, 16,000 tokens by default). Without it a model can keep doubting on a hard question and never answer: in a test, GLM-5.3 thought for 32,000 tokens five times over a C64 sprite program without writing a line; with the limit it wrote a working program on its second try.

New in 1.6: the app is called MacAIMagic (formerly MacDeepSeek), because it runs more models than DeepSeek alone. On first start it moves its folder in `~/Library/Application Support` (models, conversations, measurements) and its settings over from the former name; a work folder's notes file under the former name still works.

New in 1.5.1: the writing speed is read from the engine itself, so it also shows when another program (the API) uses the model; and the chat says when the engine is busy with another request, instead of seeming to hang.

New in 1.5: the app speaks English, German, French and Dutch (Settings; at first your Mac's language), also in its instructions to the model. A context meter in the chat, and a full conversation is summarized automatically (context up to 1M for DeepSeek and GLM). Images paste with ⌘V while typing.

New in 1.4.4: general notes for the model in every conversation, in `~/Library/Application Support/MacAIMagic/MACAIMAGIC.md` (Settings → Chat → Open bestand); a work folder's own MACAIMAGIC.md comes after them.

New in 1.4.3: a `MACAIMAGIC.md` in the work folder gives the model notes for that folder (like `CLAUDE.md`), and programs with a window are started detached, so the command time-out no longer closes them.

New in 1.4.2: a rights matrix for the work folder instead of a question for every step: the **L S U** button next to the folder sets Read, Write and Run to Allow, Ask first or Deny (also under Settings).

New in 1.4.1: an earlier conversation opens at its last message (it opened in the middle when you came back to it from another screen).

New in 1.4: the Q4 models, larger than memory, are 2.5–3× faster at writing and 7–13× at reading prompts.
DeepSeek-V4.1-Flash Q4 writes at 7–8.5 tok/s instead of 2.8 and reads prompts at 65–95 tok/s instead of 9;
GLM-5.3-Flash Q4 writes at 5–6 tok/s instead of 2.2 and reads prompts at 70–100 tok/s instead of 8. The GPU keeps the
experts a conversation uses most (~95 GB) and reads the others from the SSD with many parallel reads (6 GB/s instead of
1 GB/s); it guesses the next layer's experts and reads them ahead. The cache is saved when the engine stops, so after a
restart the first answer is as fast as the later ones. In a cluster the helpers take whole layers and the main Mac keeps
the rest with the same expert cache; helpers can raise their GPU limit to take more. To make room for the cache, raise
the GPU limit with the button under Modellen.

New in 1.3: Cluster — link several Macs with Thunderbolt and use their memory together (helper Macs lend their GPU, found automatically with Bonjour). Install this same app on every Mac.

New in 1.2.3: DeepSeek-V4.1-Flash Q4 writes correctly (its Engram table is now downloaded in Q6_K; the published MXFP8 table is misread by standard llama.cpp) and runs at ~2.8 tok/s.

New in 1.2.2: the app is quiet when idle (from ~60% CPU to under 1%): animations only run while the model works, and the metrics are sampled less often when the engine is off.

New in 1.2.1: a mini live dashboard at the bottom of the sidebar (speed gauge and sparklines for GPU, CPU, memory and SSD), and a still background (the moving one can be switched on in the settings).

New in 1.2: Qwen3.8-Flash-Next as a fifth model; faster writing with multi-token prediction (GLM and Qwen); the model can
work in a folder per chat (read, write and edit files, run scripts and commands, read logs, with your approval); the Mac
stays awake while the engine runs; the Q4 models load and run (slowly) on a 128 GB Mac.

New in 1.1: four models (DeepSeek-V4.1-Flash and GLM-5.3-Flash, each Compact and Q4), a live dashboard with real-time charts, a side-by-side comparison, and a new look.
