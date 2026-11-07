import Foundation

/// Telegram as a way into the chat: each paired account has one conversation that goes on ("✈︎ Telegram · name"),
/// the answer grows in Telegram while the model writes, an approval comes as a card with buttons (never one that needs
/// administrator rights: that stays on the Mac), and tasks and the heartbeat report there too.
@MainActor
final class TelegramBridge {
    let service: TelegramService
    let chat: ChatClient
    let store: ConversationStore
    /// The engine's address, whether the model runs, loading it (false: it cannot), a short state for /status.
    var baseURL: () -> URL
    var modelRunning: () -> Bool
    var ensureModel: () async -> Bool
    var statusText: () -> String
    /// How often the answer in Telegram is brought up to date while the model writes.
    var editInterval: Duration = .milliseconds(1500)
    /// Speech to text for voice messages (tests give a stand-in).
    var transcribe: (URL) async -> (text: String?, error: String?) = { await Voice.transcribe($0) }

    private struct Card {
        let chat: Int64
        let message: Int
        let conversation: Conversation.ID
        let text: String
    }
    /// The approval cards in Telegram that still have their buttons, by approval id.
    private var cards: [UUID: Card] = [:]
    /// The runs whose answer goes to Telegram now.
    private var streams: [Conversation.ID: Task<Void, Never>] = [:]

    init(service: TelegramService, chat: ChatClient, store: ConversationStore,
         baseURL: @escaping () -> URL, modelRunning: @escaping () -> Bool,
         ensureModel: @escaping () async -> Bool, statusText: @escaping () -> String) {
        self.service = service
        self.chat = chat
        self.store = store
        self.baseURL = baseURL
        self.modelRunning = modelRunning
        self.ensureModel = ensureModel
        self.statusText = statusText
        service.onMessage = { [weak self] m, a in self?.received(m, from: a) }
        service.onCallback = { [weak self] q, a in await self?.pressed(q, by: a) }
    }

    static func title(_ account: TelegramAccount) -> String { "✈︎ Telegram · " + account.name }

    /// The account's conversation: the newest one it has, or a new one.
    func conversation(for account: TelegramAccount, new: Bool = false) -> Conversation.ID {
        if !new, let c = store.conversations.first(where: { $0.telegram == account.id }) { return c.id }
        var c = Conversation(title: Self.title(account))
        c.telegram = account.id
        store.conversations.insert(c, at: 0)
        store.save()
        return c.id
    }

    // MARK: - messages

    /// Not awaited by the poll loop: loading the model can take minutes, and the buttons must keep working meanwhile.
    private func received(_ m: TelegramBot.Message, from account: TelegramAccount) {
        Task { await handle(m, from: account) }
    }

    func handle(_ m: TelegramBot.Message, from account: TelegramAccount) async {
        guard let bot = service.bot else { return }
        let chatID = m.chat.id
        let text = (m.text ?? m.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") {
            await command(text, account, bot, chatID)
            return
        }
        var prompt = text
        if let voice = m.voice {
            guard Settings.shared.featureVoice else {
                _ = try? await bot.send(chatID, L("Spraakberichten staan uit op de Mac (Instellingen → Agent → Spraak). Typ je vraag, of stuur een foto."))
                return
            }
            await bot.typing(chatID)
            let heard: (text: String?, error: String?)
            do {
                let data = try await bot.download(voice.fileId)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-\(UUID().uuidString).ogg")
                try data.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                heard = await transcribe(file)
            } catch {
                heard = (nil, error.localizedDescription)
            }
            guard let words = heard.text, !words.isEmpty else {
                _ = try? await bot.send(chatID, L("Ik kon het spraakbericht niet verstaan: \(heard.error ?? "")"))
                return
            }
            _ = try? await bot.send(chatID, "🎙 " + words)
            prompt = words + (prompt.isEmpty ? "" : "\n\n" + prompt)
        }
        var attachments: [Attachment] = []
        if let photo = m.photo?.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            guard Settings.shared.vision else {
                _ = try? await bot.send(chatID, L("Foto's bekijken staat uit (Instellingen → Chat → Afbeeldingen)."))
                return
            }
            do { attachments.append(Attachment(filename: "telegram.jpg", jpeg: try await bot.download(photo.fileId))) } catch {
                _ = try? await bot.send(chatID, L("De foto kwam niet over: \(error.localizedDescription)"))
                return
            }
        }
        if let doc = m.document {
            guard (doc.fileSize ?? 0) <= 1_000_000, let data = try? await bot.download(doc.fileId),
                  let body = String(data: data, encoding: .utf8), !body.contains("\u{0}") else {
                _ = try? await bot.send(chatID, L("Dit soort bestand kan ik via Telegram nog niet lezen. Stuur tekst (tot 1 MB) of een foto."))
                return
            }
            prompt += (prompt.isEmpty ? "" : "\n\n") + "[\(doc.fileName ?? "bestand")]\n```\n\(body)\n```"
        }
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        let id = conversation(for: account)
        if chat.isBusy(id) {
            _ = try? await bot.send(chatID, L("Ik ben nog bezig met je vorige vraag. /stop stopt die."))
            return
        }
        if !modelRunning() {
            _ = try? await bot.send(chatID, L("Model laden… dat kan een paar minuten duren."))
            guard await ensureModel() else {
                _ = try? await bot.send(chatID, L("Het model kon niet starten. Kijk op de Mac bij Modellen."))
                return
            }
        }
        await bot.typing(chatID)
        chat.send(text: prompt, attachments: attachments, in: id, store: store, baseURL: baseURL())
        stream(id, to: chatID)
    }

    private func command(_ text: String, _ account: TelegramAccount, _ bot: TelegramBot, _ chatID: Int64) async {
        let word = text.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        switch word.split(separator: "@").first.map(String.init) ?? word {
        case "/nieuw", "/new":
            _ = conversation(for: account, new: true)
            _ = try? await bot.send(chatID, L("Nieuw gesprek. Waar kan ik je mee helpen?"))
        case "/stop":
            if let c = store.conversations.first(where: { $0.telegram == account.id }), chat.isBusy(c.id) {
                chat.stop(c.id)
                _ = try? await bot.send(chatID, L("Gestopt."))
            } else {
                _ = try? await bot.send(chatID, L("Er loopt nu niets."))
            }
        case "/status":
            _ = try? await bot.send(chatID, statusText())
        default:
            _ = try? await bot.send(chatID, L("Stuur gewoon je vraag; het model op je Mac antwoordt. /nieuw begint een nieuw gesprek, /stop stopt het antwoord, /status zegt hoe de Mac ervoor staat."))
        }
    }

    // MARK: - the answer

    /// The visible answer of this run: the newest assistant message after the last question, with its text or error.
    private func answer(_ id: Conversation.ID) -> ChatMessage? {
        guard let c = store.conversations.first(where: { $0.id == id }),
              let q = c.messages.lastIndex(where: { $0.role == .user }) else { return nil }
        return c.messages[(q + 1)...].last { $0.role == .assistant && (!$0.text.isEmpty || $0.error != nil) }
    }

    /// Sends the answer as it grows (at most once per editInterval), and in full when the run is done.
    func stream(_ id: Conversation.ID, to chatID: Int64) {
        streams[id]?.cancel()
        streams[id] = Task { [weak self] in
            guard let self, let bot = self.service.bot else { return }
            var sent: (message: Int, for: UUID)?
            var shown = ""
            var typed = Date()
            while self.chat.isBusy(id) && !Task.isCancelled {
                try? await Task.sleep(for: self.editInterval)
                guard let a = self.answer(id), a.error == nil else {
                    if Date().timeIntervalSince(typed) > 4.5 { await bot.typing(chatID); typed = Date() }
                    continue
                }
                let now = a.text.count > TelegramFormat.limit ? String(a.text.prefix(TelegramFormat.limit)) + " …" : a.text
                if now == shown && sent?.for == a.id { continue }
                if let s = sent, s.for == a.id {
                    try? await bot.edit(chatID, s.message, now + " …")
                } else if let m = try? await bot.send(chatID, now + " …") {
                    sent = (m, a.id)
                }
                shown = now
            }
            guard !Task.isCancelled else { return }
            await self.finish(id, chatID, bot, sent: sent)
            self.streams[id] = nil
        }
    }

    private func finish(_ id: Conversation.ID, _ chatID: Int64, _ bot: TelegramBot, sent: (message: Int, for: UUID)?) async {
        // the cards of this run that nobody answered in Telegram lose their buttons
        for (key, card) in cards where card.conversation == id {
            try? await bot.edit(card.chat, card.message, card.text)
            cards[key] = nil
        }
        guard let a = answer(id) else {
            _ = try? await bot.send(chatID, L("(geen antwoord)"))
            return
        }
        if let error = a.error {
            _ = try? await bot.send(chatID, "⚠️ " + error)
            return
        }
        let parts = TelegramFormat.chunks(a.text)
        for (i, part) in parts.enumerated() {
            if i == 0, let s = sent, s.for == a.id {
                try? await bot.edit(chatID, s.message, part, html: TelegramFormat.html(part))
            } else {
                _ = try? await bot.send(chatID, part, html: TelegramFormat.html(part))
            }
        }
    }

    // MARK: - approvals

    /// A run waits for a yes: a card in Telegram for a Telegram conversation, and for a task when its results go to
    /// Telegram. Administrator rights are only approved on the Mac.
    func approval(_ a: ChatClient.Approval, isTask: Bool) {
        guard let bot = service.bot, service.isOnline else { return }
        let c = store.conversations.first { $0.id == a.conversation }
        let target = c?.telegram ?? (isTask && Settings.shared.telegramNotify ? service.notifyTarget?.id : nil)
        guard let target else { return }
        let name = c?.displayTitle ?? ""
        var lines = [isTask ? L("Taak '\(name)' vraagt toestemming:") : L("Toestemming nodig:"), a.title]
        if !a.detail.isEmpty { lines.append(String(a.detail.prefix(1500))) }
        lines += a.warnings.map { "⚠️ " + $0 }
        for step in a.steps.prefix(10) { lines.append("• " + step.title + (step.admin ? " (" + L("beheerder") + ")" : "")) }
        let text = lines.joined(separator: "\n")
        Task {
            if a.admin {
                _ = try? await bot.send(target, text + "\n\n" + L("Dit vraagt beheerdersrechten; keur het goed op de Mac."))
                Notifier.shared.post(title: L("Goedkeuring nodig: \(name)"), body: a.title, conversation: a.conversation)
                return
            }
            let key = a.id.uuidString
            var buttons = [[TelegramBot.Button(text: L("Toestaan"), data: "a:" + key), TelegramBot.Button(text: L("Weigeren"), data: "n:" + key)]]
            if !a.everyTime { buttons.append([TelegramBot.Button(text: L("Altijd in dit gesprek"), data: "t:" + key)]) }
            guard let m = try? await bot.send(target, text, buttons: buttons) else { return }
            // the approval may have been answered on the Mac meanwhile
            if chat.approvals[a.conversation]?.id == a.id {
                cards[a.id] = Card(chat: target, message: m, conversation: a.conversation, text: text)
            } else {
                try? await bot.edit(target, m, text)
            }
        }
        if !isTask {
            // as with a task: no answer within a day is a no
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(24 * 3600))
                guard let self, let still = self.chat.approvals[a.conversation], still.id == a.id else { return }
                self.chat.answer(still, allow: false)
            }
        }
    }

    func pressed(_ q: TelegramBot.CallbackQuery, by account: TelegramAccount) async {
        guard let bot = service.bot else { return }
        let parts = (q.data ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { await bot.answerCallback(q.id); return }
        guard let card = cards[id], card.chat == account.id,
              let approval = chat.approvals[card.conversation], approval.id == id else {
            await bot.answerCallback(q.id, L("Deze vraag is al beantwoord."))
            if let m = q.message { try? await bot.edit(m.chat.id, m.messageId, m.text ?? "") }
            cards[id] = nil
            return
        }
        cards[id] = nil
        let allow = parts[0] != "n"
        chat.answer(approval, allow: allow, always: parts[0] == "t" && !approval.everyTime)
        let result = parts[0] == "t" ? L("Altijd toegestaan in dit gesprek") : allow ? L("Toegestaan") : L("Geweigerd")
        await bot.answerCallback(q.id, result)
        try? await bot.edit(card.chat, card.message, card.text + "\n\n" + (allow ? "✅ " : "❌ ") + result)
    }

    // MARK: - notifications

    /// A task or the heartbeat has something to say: also to Telegram, when that is on.
    func notify(_ title: String, _ body: String) {
        guard Settings.shared.telegramNotify, let bot = service.bot, service.isOnline, let to = service.notifyTarget else { return }
        let text = title + (body.isEmpty ? "" : "\n" + body)
        Task { _ = try? await bot.send(to.id, String(text.prefix(TelegramFormat.limit))) }
    }
}
