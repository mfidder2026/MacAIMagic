import Foundation

/// Telegram's Bot API, the parts MacAIMagic uses. The Mac only calls out to api.telegram.org (long polling): nothing
/// listens on this Mac, and no server is needed. The token is in the Keychain (`TelegramBot.keychainAccount`).
struct TelegramBot {
    static let keychainAccount = "telegram-bot"
    static let api = URL(string: "https://api.telegram.org")!

    let token: String
    var base: URL = TelegramBot.api
    var session: URLSession = .shared

    enum BotError: LocalizedError, Equatable {
        /// 401: the token is wrong or was revoked.
        case unauthorized
        /// 409: another program polls this bot.
        case conflict
        case api(Int, String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return L("Telegram kent deze token niet. Maak een nieuwe bij @BotFather en plak hem opnieuw.")
            case .conflict: return L("Een ander programma gebruikt deze bot al (getUpdates). Stop dat, of maak een eigen bot voor MacAIMagic.")
            case .api(let code, let text): return "Telegram \(code): \(text)"
            case .network(let text): return L("Geen verbinding met Telegram: \(text)")
            }
        }
    }

    // MARK: - what Telegram sends

    struct User: Decodable, Equatable {
        let id: Int64
        let isBot: Bool?
        let firstName: String?
        let lastName: String?
        let username: String?
        var name: String {
            let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            return full.isEmpty ? (username.map { "@" + $0 } ?? String(id)) : full
        }
    }
    struct Chat: Decodable, Equatable {
        let id: Int64
        let type: String
    }
    struct PhotoSize: Decodable, Equatable {
        let fileId: String
        let width: Int
        let height: Int
        let fileSize: Int?
    }
    struct Document: Decodable, Equatable {
        let fileId: String
        let fileName: String?
        let mimeType: String?
        let fileSize: Int?
    }
    struct Message: Decodable, Equatable {
        let messageId: Int
        let from: User?
        let chat: Chat
        let text: String?
        let caption: String?
        let photo: [PhotoSize]?
        let document: Document?
        let voice: Voice?
        struct Voice: Decodable, Equatable { let fileId: String }
    }
    struct CallbackQuery: Decodable, Equatable {
        let id: String
        let from: User
        let message: Message?
        let data: String?
    }
    struct Update: Decodable, Equatable {
        let updateId: Int
        let message: Message?
        let callbackQuery: CallbackQuery?
    }
    struct Button { let text: String; let data: String }

    // MARK: - calls

    private struct Reply<T: Decodable>: Decodable {
        let ok: Bool
        let result: T?
        let description: String?
        let errorCode: Int?
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func url(_ method: String) -> URL { base.appendingPathComponent("bot" + token).appendingPathComponent(method) }

    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], wait: TimeInterval = 30) async throws -> T {
        var req = URLRequest(url: url(method), timeoutInterval: wait)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch {
            // the token is in the address: never show it
            throw BotError.network(error.localizedDescription.replacingOccurrences(of: token, with: "…"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = try? Self.decoder.decode(Reply<T>.self, from: data)
        if status == 401 || reply?.errorCode == 401 { throw BotError.unauthorized }
        if status == 409 || reply?.errorCode == 409 { throw BotError.conflict }
        guard let reply, reply.ok, let result = reply.result else {
            throw BotError.api(reply?.errorCode ?? status, reply?.description ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
        return result
    }

    func me() async throws -> User { try await call("getMe") }

    /// Waits up to `timeout` seconds for something new (long polling).
    func updates(offset: Int, timeout: Int = 50) async throws -> [Update] {
        try await call("getUpdates", ["offset": offset, "timeout": timeout, "allowed_updates": ["message", "callback_query"]],
                       wait: TimeInterval(timeout + 20))
    }

    private struct Sent: Decodable { let messageId: Int }

    /// Sends one message (at most 4096 characters, see TelegramFormat.chunks) as HTML, or as plain text when
    /// Telegram does not take the HTML. Returns its id.
    @discardableResult
    func send(_ chat: Int64, _ text: String, html: String? = nil, buttons: [[Button]] = []) async throws -> Int {
        var p: [String: Any] = ["chat_id": chat, "text": html ?? text, "link_preview_options": ["is_disabled": true]]
        if html != nil { p["parse_mode"] = "HTML" }
        if !buttons.isEmpty { p["reply_markup"] = Self.keyboard(buttons) }
        do {
            let sent: Sent = try await call("sendMessage", p)
            return sent.messageId
        } catch BotError.api(400, _) where html != nil {
            p["text"] = text
            p["parse_mode"] = nil
            let sent: Sent = try await call("sendMessage", p)
            return sent.messageId
        }
    }

    /// Replaces a message's text (an answer that grows, a card that was answered). "Not modified" is no error.
    func edit(_ chat: Int64, _ message: Int, _ text: String, html: String? = nil, buttons: [[Button]] = []) async throws {
        var p: [String: Any] = ["chat_id": chat, "message_id": message, "text": html ?? text, "link_preview_options": ["is_disabled": true]]
        if html != nil { p["parse_mode"] = "HTML" }
        p["reply_markup"] = Self.keyboard(buttons)
        do {
            let _: AnyDecodable = try await call("editMessageText", p)
        } catch BotError.api(400, let why) where why.contains("not modified") {
        } catch BotError.api(400, _) where html != nil {
            p["text"] = text
            p["parse_mode"] = nil
            let _: AnyDecodable = try await call("editMessageText", p)
        }
    }

    func typing(_ chat: Int64) async {
        let _: AnyDecodable? = try? await call("sendChatAction", ["chat_id": chat, "action": "typing"])
    }

    /// The little note after a button press (and it stops the button's spinner).
    func answerCallback(_ id: String, _ text: String? = nil) async {
        var p: [String: Any] = ["callback_query_id": id]
        if let text { p["text"] = text }
        let _: AnyDecodable? = try? await call("answerCallbackQuery", p)
    }

    private struct File: Decodable { let filePath: String? }

    /// A file someone sent (a photo, a document), at most 20 MB (the Bot API's own limit).
    func download(_ fileID: String) async throws -> Data {
        let file: File = try await call("getFile", ["file_id": fileID])
        guard let path = file.filePath else { throw BotError.api(404, "no file_path") }
        let address = base.appendingPathComponent("file").appendingPathComponent("bot" + token).appendingPathComponent(path)
        do {
            let (data, response) = try await session.data(from: address)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BotError.api(404, "file") }
            return data
        } catch let e as BotError { throw e } catch { throw BotError.network(error.localizedDescription.replacingOccurrences(of: token, with: "…")) }
    }

    static func keyboard(_ rows: [[Button]]) -> [String: Any] {
        ["inline_keyboard": rows.map { $0.map { ["text": $0.text, "callback_data": $0.data] } }]
    }
}

/// For calls whose result does not matter (true, or a message).
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}
