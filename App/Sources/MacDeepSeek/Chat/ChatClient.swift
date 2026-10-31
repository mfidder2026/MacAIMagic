import Foundation

/// Talks to the local engine's OpenAI-compatible endpoint: streams answers and thinking, and runs the tool loop
/// (web search, page reading) until the model answers without calling a tool.
@MainActor
final class ChatClient: ObservableObject {
    @Published private(set) var busy = false
    /// Gets a token count per streamed delta, for the live speed chart.
    weak var metrics: LiveMetrics?
    /// The model the engine runs, for the system prompt.
    var modelName = "DeepSeek-V4.1-Flash"
    private var task: Task<Void, Never>?
    private let maxToolRounds = 8

    func stop() { task?.cancel() }

    func send(text: String, attachments: [Attachment], in conversation: Conversation.ID, store: ConversationStore, baseURL: URL) {
        guard !busy else { return }
        store.update(conversation) { c in
            c.messages.append(ChatMessage(role: .user, text: text, attachments: attachments))
            if c.title == "Nieuw gesprek" {
                let t = text.isEmpty ? (attachments.first?.filename ?? "Afbeelding") : text
                c.title = String(t.prefix(48)).replacingOccurrences(of: "\n", with: " ")
            }
        }
        busy = true
        task = Task {
            await run(conversation, store: store, baseURL: baseURL)
            busy = false
            store.save()
        }
    }

    private func run(_ id: Conversation.ID, store: ConversationStore, baseURL: URL) async {
        var activities: [ToolActivity] = []
        var sources: [Source] = []
        for _ in 0..<maxToolRounds {
            let reply = ChatMessage(role: .assistant, text: "", activities: activities, sources: sources)
            store.update(id) { $0.messages.append(reply) }
            guard let history = store.conversations.first(where: { $0.id == id })?.messages.dropLast() else { return }

            let result: StreamResult
            do {
                result = try await stream(history: Array(history), baseURL: baseURL) { delta in
                    store.update(id) { c in
                        guard let i = c.messages.lastIndex(where: { $0.id == reply.id }) else { return }
                        c.messages[i].text += delta.content
                        c.messages[i].reasoning += delta.reasoning
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                store.update(id) { c in
                    if let i = c.messages.lastIndex(where: { $0.id == reply.id }) { c.messages[i].error = error.localizedDescription }
                }
                return
            }

            store.update(id) { c in
                guard let i = c.messages.lastIndex(where: { $0.id == reply.id }) else { return }
                c.messages[i].toolCalls = result.toolCalls
                c.messages[i].tokensPerSecond = result.tokensPerSecond
                c.messages[i].promptTokensPerSecond = result.promptTokensPerSecond
            }
            guard !result.toolCalls.isEmpty, !Task.isCancelled else { return }

            // run the tools; the next round's message carries the activity list, this one folds away
            for call in result.toolCalls {
                activities.append(ToolActivity(label: WebTools.label(for: call), done: false))
                store.update(id) { c in
                    if let i = c.messages.lastIndex(where: { $0.id == reply.id }) { c.messages[i].activities = activities }
                }
                let out = await WebTools.run(call)
                activities[activities.count - 1].done = true
                for s in out.sources where !sources.contains(where: { $0.url == s.url }) { sources.append(s) }
                store.update(id) { c in
                    if let i = c.messages.lastIndex(where: { $0.id == reply.id }) {
                        c.messages[i].activities = []
                        c.messages[i].sources = []
                    }
                    c.messages.append(ChatMessage(role: .tool, text: out.text, toolCallId: call.id))
                }
            }
        }
    }

    // MARK: - request

    private func requestMessages(_ history: [ChatMessage]) -> [[String: Any]] {
        let s = Settings.shared
        let df = DateFormatter()
        df.locale = Locale(identifier: "nl_NL")
        df.dateStyle = .full
        var system = "Je bent \(modelName), lokaal draaiend op de Mac van de gebruiker via MacDeepSeek. Vandaag is het \(df.string(from: Date()))."
        if s.webSearch {
            system += " Je kunt het web doorzoeken met web_search en pagina's lezen met fetch_url. Doe dat voor actuele informatie en noem je bronnen met hun URL."
        }
        if !s.systemPrompt.isEmpty { system += "\n\n" + s.systemPrompt }

        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in history {
            switch m.role {
            case .system: continue
            case .user:
                if m.attachments.isEmpty {
                    out.append(["role": "user", "content": m.text])
                } else {
                    var parts: [[String: Any]] = m.attachments.map {
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.jpeg.base64EncodedString()]]
                    }
                    if !m.text.isEmpty { parts.append(["type": "text", "text": m.text]) }
                    out.append(["role": "user", "content": parts])
                }
            case .assistant:
                if m.error != nil && m.text.isEmpty { continue }
                var msg: [String: Any] = ["role": "assistant", "content": m.text]
                if !m.toolCalls.isEmpty {
                    msg["tool_calls"] = m.toolCalls.map {
                        ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                    }
                }
                out.append(msg)
            case .tool:
                out.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.text])
            }
        }
        return out
    }

    struct Delta { var content = ""; var reasoning = "" }
    struct StreamResult { var toolCalls: [ToolCall] = []; var tokensPerSecond: Double?; var promptTokensPerSecond: Double? }

    private func stream(history: [ChatMessage], baseURL: URL, onDelta: (Delta) -> Void) async throws -> StreamResult {
        let s = Settings.shared
        var body: [String: Any] = [
            "model": modelName,
            "messages": requestMessages(history),
            "stream": true,
            "temperature": s.temperature,
            "top_p": 1.0,
            // enable_thinking is understood by both templates (DeepSeek maps it to thinking_mode)
            "chat_template_kwargs": ["enable_thinking": s.thinking, "reasoning_effort": s.reasoningEffort],
        ]
        if s.webSearch { body["tools"] = WebTools.definitions }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !s.apiKey.isEmpty { req.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 3600

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            var msg = ""
            for try await line in bytes.lines { msg += line }
            throw NSError(domain: "MacDeepSeek", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Engine gaf \(http.statusCode): \(msg.prefix(400))"])
        }

        var result = StreamResult()
        var calls: [Int: ToolCall] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let t = json["timings"] as? [String: Any] {
                result.tokensPerSecond = t["predicted_per_second"] as? Double
                result.promptTokensPerSecond = t["prompt_per_second"] as? Double
            }
            guard let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }
            var d = Delta()
            d.content = delta["content"] as? String ?? ""
            d.reasoning = delta["reasoning_content"] as? String ?? ""
            if !d.content.isEmpty || !d.reasoning.isEmpty {
                onDelta(d)
                metrics?.addTokens(1)   // the server streams one token per chunk
            }
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let idx = tc["index"] as? Int ?? 0
                var call = calls[idx] ?? ToolCall(id: "", name: "", arguments: "")
                if let id = tc["id"] as? String, !id.isEmpty { call.id = id }
                if let f = tc["function"] as? [String: Any] {
                    call.name += f["name"] as? String ?? ""
                    call.arguments += f["arguments"] as? String ?? ""
                }
                calls[idx] = call
            }
        }
        result.toolCalls = calls.sorted { $0.key < $1.key }.map { k, v in
            var c = v
            if c.id.isEmpty { c.id = "call_\(k)_\(UUID().uuidString.prefix(8))" }
            return c
        }
        return result
    }
}
