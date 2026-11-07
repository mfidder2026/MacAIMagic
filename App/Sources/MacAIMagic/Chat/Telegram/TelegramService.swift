import Foundation

/// A Telegram account that may talk to this Mac: it sent the pairing code once.
struct TelegramAccount: Codable, Identifiable, Hashable {
    let id: Int64
    var name: String
}

/// Who may talk to the bot. Only accounts that sent the pairing code, in a private chat; everybody else is ignored
/// without an answer, so a stranger cannot even tell that the bot is there.
struct TelegramAccess {
    var accounts: [TelegramAccount] = []
    private(set) var code: String?
    private(set) var codeUntil: Date?
    static let codeMinutes = 10.0

    enum Decision: Equatable {
        case allowed(TelegramAccount)
        /// This message was the pairing code: the account is in now.
        case paired(TelegramAccount)
        case ignored
    }

    mutating func newCode(now: Date = Date()) -> String {
        let c = String(format: "%06d", Int.random(in: 0...999_999))
        code = c
        codeUntil = now.addingTimeInterval(Self.codeMinutes * 60)
        return c
    }

    mutating func cancelCode() { code = nil; codeUntil = nil }

    func isAllowed(_ id: Int64) -> Bool { accounts.contains { $0.id == id } }

    mutating func decide(_ message: TelegramBot.Message, now: Date = Date()) -> Decision {
        guard message.chat.type == "private", let from = message.from, from.isBot != true, message.chat.id == from.id else { return .ignored }
        if let known = accounts.first(where: { $0.id == from.id }) { return .allowed(known) }
        guard let code, let until = codeUntil, now < until else { return .ignored }
        let words = (message.text ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.last == code, words.count == 1 || (words.count == 2 && words[0].hasPrefix("/start")) else { return .ignored }
        let account = TelegramAccount(id: from.id, name: from.name)
        accounts.append(account)
        cancelCode()
        return .paired(account)
    }
}

/// Keeps the connection with the bot: polls Telegram, lets in only the paired accounts, and hands their messages and
/// button presses to the bridge.
@MainActor
final class TelegramService: ObservableObject {
    static let shared = TelegramService()

    enum Status: Equatable {
        case off
        case noToken
        case connecting
        case online(String)
        case problem(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var access: TelegramAccess
    /// The last lines of what happened, without message texts (Instellingen → Telegram).
    @Published private(set) var log: [String] = []
    /// A message or a button press from a paired account.
    var onMessage: ((TelegramBot.Message, TelegramAccount) async -> Void)?
    var onCallback: ((TelegramBot.CallbackQuery, TelegramAccount) async -> Void)?
    /// Tests point at a stand-in and keep the token and the accounts in memory.
    var base = TelegramBot.api
    private var testToken: String?
    private let defaults: UserDefaults
    private var poll: Task<Void, Never>?
    private var pollTimeout = 50

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "telegramAccounts").flatMap { try? JSONDecoder().decode([TelegramAccount].self, from: $0) } ?? []
        access = TelegramAccess(accounts: saved)
    }

    /// For tests: a stand-in server, a token that never touches the Keychain, short polls.
    func useForTests(base: URL, token: String, pollTimeout: Int = 1) {
        self.base = base
        testToken = token
        self.pollTimeout = pollTimeout
    }

    var token: String? {
        get { testToken ?? MCPKeychain.get(TelegramBot.keychainAccount) }
    }

    func setToken(_ value: String) {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if testToken != nil { testToken = t } else if t.isEmpty { MCPKeychain.delete(TelegramBot.keychainAccount) } else { MCPKeychain.set(t, for: TelegramBot.keychainAccount) }
        defaults.removeObject(forKey: "telegramOffset")
        restart()
    }

    var bot: TelegramBot? { token.map { TelegramBot(token: $0, base: base) } }
    var isOnline: Bool { if case .online = status { return true } else { return false } }
    var accounts: [TelegramAccount] { access.accounts }
    /// Where task results and the heartbeat go: the first account paired.
    var notifyTarget: TelegramAccount? { access.accounts.first }

    private var offset: Int {
        get { defaults.integer(forKey: "telegramOffset") }
        set { defaults.set(newValue, forKey: "telegramOffset") }
    }

    func note(_ line: String) {
        log.append(Date().formatted(date: .omitted, time: .standard) + "  " + line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    // MARK: - pairing

    func newCode() -> String { access.newCode() }
    func cancelCode() { access.cancelCode() }
    var code: String? { access.code }

    func unpair(_ id: Int64) {
        access.accounts.removeAll { $0.id == id }
        saveAccounts()
    }

    private func saveAccounts() {
        defaults.set(try? JSONEncoder().encode(access.accounts), forKey: "telegramAccounts")
    }

    // MARK: - polling

    func start() {
        guard poll == nil else { return }
        guard Settings.shared.featureTelegram || testToken != nil else { status = .off; return }
        guard let bot else { status = .noToken; return }
        status = .connecting
        poll = Task { [weak self] in await self?.loop(bot) }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        status = Settings.shared.featureTelegram && token == nil ? .noToken : .off
    }

    func restart() { stop(); start() }

    private func loop(_ bot: TelegramBot) async {
        var wait = 5.0
        do {
            let me = try await bot.me()
            status = .online("@" + (me.username ?? me.name))
            note(L("Verbonden als @\(me.username ?? me.name)"))
        } catch {
            if !Task.isCancelled { failed(error) }
            if (error as? TelegramBot.BotError) == .unauthorized { poll = nil; return }
        }
        while !Task.isCancelled {
            do {
                let updates = try await bot.updates(offset: offset, timeout: pollTimeout)
                if case .online = status {} else if let me = try? await bot.me() { status = .online("@" + (me.username ?? me.name)) }
                wait = 5
                for u in updates {
                    offset = max(offset, u.updateId + 1)
                    await handle(u, bot)
                }
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                failed(error)
                if (error as? TelegramBot.BotError) == .unauthorized { break }
                try? await Task.sleep(for: .seconds((error as? TelegramBot.BotError) == .conflict ? 30 : wait))
                wait = min(wait * 2, 60)
            }
        }
        poll = nil
    }

    private func failed(_ error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        status = .problem(text)
        note(text)
    }

    func handle(_ u: TelegramBot.Update, _ bot: TelegramBot) async {
        if let m = u.message {
            switch access.decide(m) {
            case .ignored:
                note(L("Bericht van een onbekend account genegeerd (id \(m.from?.id ?? m.chat.id))."))
            case .paired(let a):
                saveAccounts()
                note(L("Gekoppeld: \(a.name)"))
                _ = try? await bot.send(m.chat.id, L("Gekoppeld. Je kunt nu met MacAIMagic op je Mac praten. /nieuw begint een nieuw gesprek, /stop stopt het antwoord, /status zegt hoe de Mac ervoor staat."))
            case .allowed(let a):
                await onMessage?(m, a)
            }
        } else if let q = u.callbackQuery {
            guard let a = access.accounts.first(where: { $0.id == q.from.id }) else {
                await bot.answerCallback(q.id)
                return
            }
            await onCallback?(q, a)
        }
    }
}
