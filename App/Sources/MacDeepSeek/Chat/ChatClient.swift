import Foundation

/// Talks to the local engine's OpenAI-compatible endpoint: streams answers and thinking, and runs the tool loop
/// (web search, page reading) until the model answers without calling a tool.
@MainActor
final class ChatClient: ObservableObject {
    @Published private(set) var busy = false
    /// Summarizing the start of a conversation to free context.
    @Published private(set) var compacting = false
    /// The engine's context in tokens (set when it starts).
    var contextLimit = 65_536
    /// At this share of the context the conversation is summarized before the next request.
    static let compactAt = 0.8
    /// Gets a token count per streamed delta, for the live speed chart.
    weak var metrics: LiveMetrics?
    /// The model the engine runs, for the system prompt.
    var modelName = "DeepSeek-V4.1-Flash"
    private var task: Task<Void, Never>?
    /// Web questions need a few rounds; work in a folder (read, write, run, read the log, fix) needs many more.
    private var maxToolRounds: Int { Settings.shared.workspaceTools && WorkspaceTools.workspace != nil ? 40 : 8 }

    /// A change the model wants to make (write a file, run a command), waiting for the user's yes or no.
    struct Approval: Identifiable {
        let id = UUID()
        let conversation: Conversation.ID
        let call: ToolCall
        let title: String
        let detail: String
    }
    @Published private(set) var pendingApproval: Approval?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    /// Conversations where the user chose "always allow".
    private var trusted: Set<Conversation.ID> = []

    func answer(_ approval: Approval, allow: Bool, always: Bool = false) {
        if always { trusted.insert(approval.conversation) }
        pendingApproval = nil
        approvalContinuation?.resume(returning: allow)
        approvalContinuation = nil
    }

    private func askApproval(_ call: ToolCall, in conversation: Conversation.ID) async -> Bool {
        if trusted.contains(conversation) { return true }
        let text = WorkspaceTools.approvalText(for: call)
        return await withCheckedContinuation { cont in
            approvalContinuation = cont
            pendingApproval = Approval(conversation: conversation, call: call, title: text.title, detail: text.detail)
        }
    }

    func stop() {
        task?.cancel()
        if let a = pendingApproval { answer(a, allow: false) }
    }

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
        // this conversation's folder for the tools and the system prompt
        WorkspaceTools.current = store.conversations.first { $0.id == id }?.workspace ?? ""
        var activities: [ToolActivity] = []
        var sources: [Source] = []
        for _ in 0..<maxToolRounds {
            if let used = store.conversations.first(where: { $0.id == id })?.contextTokens,
               Double(used) > Double(contextLimit) * Self.compactAt {
                await compact(id, store: store, baseURL: baseURL)
            }
            let reply = ChatMessage(role: .assistant, text: "", activities: activities, sources: sources)
            store.update(id) { $0.messages.append(reply) }

            var result = StreamResult()
            var retried = false
            while true {
                guard let c = store.conversations.first(where: { $0.id == id }) else { return }
                do {
                    result = try await stream(history: Array(c.unsummarized.dropLast()), summary: c.summary, baseURL: baseURL) { delta in
                        store.update(id) { c in
                            guard let i = c.messages.lastIndex(where: { $0.id == reply.id }) else { return }
                            c.messages[i].text += delta.content
                            c.messages[i].reasoning += delta.reasoning
                        }
                    }
                    break
                } catch is CancellationError {
                    return
                } catch let error as NSError where !retried && error.code == 400 && error.localizedDescription.contains("context") {
                    // the conversation no longer fits: summarize its start and try again once
                    retried = true
                    await compact(id, store: store, baseURL: baseURL, excluding: reply.id)
                } catch {
                    store.update(id) { c in
                        if let i = c.messages.lastIndex(where: { $0.id == reply.id }) { c.messages[i].error = error.localizedDescription }
                    }
                    return
                }
            }
            if let used = result.contextTokens { store.update(id) { $0.contextTokens = used } }

            store.update(id) { c in
                guard let i = c.messages.lastIndex(where: { $0.id == reply.id }) else { return }
                c.messages[i].toolCalls = result.toolCalls
                c.messages[i].tokensPerSecond = result.tokensPerSecond
                c.messages[i].promptTokensPerSecond = result.promptTokensPerSecond
            }
            guard !result.toolCalls.isEmpty, !Task.isCancelled else { return }

            // run the tools; the next round's message carries the activity list, this one folds away
            for call in result.toolCalls {
                let isWorkspace = WorkspaceTools.names.contains(call.name)
                activities.append(ToolActivity(label: isWorkspace ? WorkspaceTools.label(for: call) : WebTools.label(for: call), done: false))
                store.update(id) { c in
                    if let i = c.messages.lastIndex(where: { $0.id == reply.id }) { c.messages[i].activities = activities }
                }
                var text: String
                if isWorkspace {
                    let right = Settings.shared.right(WorkspaceTools.right(for: call.name))
                    if right == "deny" {
                        text = "The user's settings do not allow this kind of action (\(WorkspaceTools.right(for: call.name).title)). Do not try it again; tell the user what you wanted to do, or continue without it."
                        activities[activities.count - 1].denied = true
                    } else if right == "ask", !(await askApproval(call, in: id)) {
                        text = "The user did not allow this. Ask what they want instead, or continue without it."
                        activities[activities.count - 1].denied = true
                    } else {
                        text = await WorkspaceTools.run(call)
                    }
                } else {
                    let out = await WebTools.run(call)
                    text = out.text
                    for s in out.sources where !sources.contains(where: { $0.url == s.url }) { sources.append(s) }
                }
                guard !Task.isCancelled else { return }
                activities[activities.count - 1].done = true
                activities[activities.count - 1].output = String(text.prefix(4000))
                store.update(id) { c in
                    if let i = c.messages.lastIndex(where: { $0.id == reply.id }) {
                        c.messages[i].activities = []
                        c.messages[i].sources = []
                    }
                    c.messages.append(ChatMessage(role: .tool, text: text, toolCallId: call.id))
                }
            }
        }
    }

    // MARK: - compacting

    /// Summarize the start of a conversation, so it fits in the context again: everything before the last two questions
    /// becomes a summary that goes with the system prompt; the messages stay visible in the chat.
    func compact(_ id: Conversation.ID, store: ConversationStore, baseURL: URL, excluding skip: UUID? = nil) async {
        guard let c = store.conversations.first(where: { $0.id == id }) else { return }
        let open = c.unsummarized.filter { $0.id != skip }
        let users = open.indices.filter { open[$0].role == .user }
        guard users.count > 2 else { return }
        let cut = users[users.count - 2]   // keep the last two questions and what came after them
        let old = open[open.startIndex..<cut]
        guard let last = old.last else { return }

        compacting = true
        defer { compacting = false }
        // a transcript without images and with long tool results shortened, so the request itself fits
        let budget = Int(Double(contextLimit) * 2.5)   // characters, about 0.7 of the context in tokens
        var lines: [String] = []
        if let previous = c.summary { lines.append(L("Eerdere samenvatting:") + "\n" + previous) }
        for m in old {
            switch m.role {
            case .user: lines.append(L("Gebruiker:") + " " + m.text + (m.attachments.isEmpty ? "" : " [" + L("afbeelding") + "]"))
            case .assistant:
                if !m.text.isEmpty { lines.append(L("Assistent:") + " " + m.text) }
                for call in m.toolCalls { lines.append(L("Assistent gebruikt \(call.name):") + " " + String(call.arguments.prefix(600))) }
            case .tool: lines.append(L("Resultaat:") + " " + String(m.text.prefix(1500)))
            case .system: continue
            }
        }
        var transcript = lines.joined(separator: "\n\n")
        if transcript.count > budget { transcript = "[" + L("begin weggelaten") + "]\n" + String(transcript.suffix(budget)) }

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": L("Je vat een gesprek samen zodat het verder kan zonder de oorspronkelijke berichten. Houd vast: het doel van de gebruiker, beslissingen, namen en paden van bestanden, commando's die werkten of faalden, de stand van het werk en open vragen of taken. Schrijf beknopt, in het Nederlands, als lijst met kopjes.")],
                ["role": "user", "content": L("Vat dit gesprek samen:") + "\n\n" + transcript],
            ],
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 2000,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Settings.shared.apiKey.isEmpty { req.setValue("Bearer \(Settings.shared.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 1800
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let summary = message["content"] as? String, !summary.isEmpty else { return }
        store.update(id) { c in
            c.summary = summary
            c.summaryUpTo = last.id
            c.contextTokens = nil
        }
        store.save()
    }

    // MARK: - request

    private func requestMessages(_ history: [ChatMessage], summary: String? = nil) -> [[String: Any]] {
        let s = Settings.shared
        let df = DateFormatter()
        df.locale = Locale(identifier: AppLanguage.current.rawValue)
        df.dateStyle = .full
        var system = L("Je bent \(modelName), lokaal draaiend op de Mac van de gebruiker via MacDeepSeek. Vandaag is het \(df.string(from: Date())).")
        if s.webSearch {
            system += " " + L("Je kunt het web doorzoeken met web_search en pagina's lezen met fetch_url. Doe dat voor actuele informatie en noem je bronnen met hun URL.")
        }
        // the user's general notes, for every conversation (the folder's notes come after them)
        if let text = try? String(contentsOf: Paths.generalNotes, encoding: .utf8), !text.isEmpty {
            system += "\n\n" + L("Algemene notities van de gebruiker (MACDEEPSEEK.md), volg ze op:") + "\n" + String(text.prefix(8000))
        }
        if s.workspaceTools, let ws = WorkspaceTools.workspace {
            system += "\n\n" + L("Je werkt in de map \(ws.path) op deze Mac. Je hebt gereedschap om daar echt te werken: list_dir, read_file (ook het einde van logbestanden met tail), write_file (ook binaire bestanden via base64, bijvoorbeeld een C64 .prg), edit_file en run_command (zsh in die map: scripts starten, code bouwen of testen, programma's openen met open). Zeg dus nooit dat je geen bestanden kunt maken of uitvoeren: doe het. Werk in stappen: bekijk eerst wat er is, maak of wijzig bestanden, voer ze uit, lees de uitvoer of het log, en verbeter tot het werkt. Een programma met een venster (een emulator, een app) start je los van run_command, met open of met & aan het eind: run_command wacht anders tot het programma stopt en breekt het af na de time-out. Afhankelijk van de rechten die de gebruiker heeft ingesteld vraagt de app soms eerst toestemming; leg kort uit wat je doet.")
            // the user's own notes for this folder, like CLAUDE.md for Claude Code
            let notes = ws.appendingPathComponent("MACDEEPSEEK.md")
            if let text = try? String(contentsOf: notes, encoding: .utf8), !text.isEmpty {
                system += "\n\n" + L("Notities van de gebruiker voor deze werkmap (MACDEEPSEEK.md), volg ze op:") + "\n" + String(text.prefix(8000))
            }
        }
        if !s.systemPrompt.isEmpty { system += "\n\n" + s.systemPrompt }
        if let summary {
            system += "\n\n" + L("Samenvatting van het begin van dit gesprek (die berichten zijn weggelaten om ruimte te maken in je context):") + "\n" + summary
        }

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
    struct StreamResult {
        var toolCalls: [ToolCall] = []
        var tokensPerSecond: Double?
        var promptTokensPerSecond: Double?
        /// Prompt and answer together: what the conversation takes in the context now.
        var contextTokens: Int?
    }

    private func stream(history: [ChatMessage], summary: String? = nil, baseURL: URL, onDelta: (Delta) -> Void) async throws -> StreamResult {
        let s = Settings.shared
        var body: [String: Any] = [
            "model": modelName,
            "messages": requestMessages(history, summary: summary),
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": s.temperature,
            "top_p": 1.0,
            // enable_thinking is understood by both templates (DeepSeek maps it to thinking_mode)
            "chat_template_kwargs": ["enable_thinking": s.thinking, "reasoning_effort": s.reasoningEffort],
        ]
        var tools: [[String: Any]] = s.webSearch ? WebTools.definitions : []
        if s.workspaceTools && WorkspaceTools.workspace != nil { tools += WorkspaceTools.definitions }
        if !tools.isEmpty { body["tools"] = tools }

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
            if let u = json["usage"] as? [String: Any], let total = u["total_tokens"] as? Int, total > 0 {
                result.contextTokens = total
            }
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
