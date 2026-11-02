import Foundation

/// Which model does what in the documents module: small work (search questions, notes, spelling) goes to a fast model
/// when one fits next to the heavy one, the real writing to the heavy one. The heavy model is the app's own engine.
enum ModelRole { case fast, heavy }

enum DocumentModels {
    /// The context of the fast model: its work is one small piece at a time.
    static let fastContext = 16_384

    /// The smallest downloaded model next to `heavy`, when both stay whole in this Mac's memory. A heavy model that
    /// streams from the SSD needs the free memory for its experts; then one model does everything.
    static func fastModel(heavy: ModelInfo?, heavyPlan: MemoryPlan?, downloaded: [ModelInfo], physical: UInt64) -> ModelInfo? {
        guard let heavy, let heavyPlan, heavyPlan.fitsInMemory else { return nil }
        let heavyMemory = heavy.memory ?? heavy.totalSize
        guard let small = downloaded.filter({ $0.id != heavy.id && ($0.memory ?? $0.totalSize) < heavyMemory })
            .min(by: { ($0.memory ?? $0.totalSize) < ($1.memory ?? $1.totalSize) }) else { return nil }
        let needed = (small.memory ?? small.totalSize) + MemoryPlanner.minimumOverhead + MemoryPlanner.osHeadroom
        return heavyPlan.resident + needed <= physical ? small : nil
    }
}

/// Starts the models for a piece of work and says where to reach them.
@MainActor
final class DocumentEngines: ObservableObject {
    /// The second engine, on the port after the app's own and only reachable from this Mac.
    let fast = EngineController(port: Settings.shared.port + 1, logFile: Paths.appSupport.appendingPathComponent("engine-fast.log"))
    private unowned let app: AppState

    init(app: AppState) { self.app = app }

    var fastChoice: ModelInfo? {
        let m = app.models
        return DocumentModels.fastModel(heavy: app.selectedModel, heavyPlan: app.plan,
                                        downloaded: m.catalog.models.filter { m.status($0.id).isComplete },
                                        physical: app.system.physicalMemory)
    }

    func endpoint(_ role: ModelRole) async throws -> (url: URL, model: String) {
        if role == .fast, let small = fastChoice {
            do {
                try await startFast(small)
                return (fast.baseURL, small.id)
            } catch {
                // a fast model that does not start must not stop the work: the heavy one can do it too
                fast.stop()
            }
        }
        return try await heavy()
    }

    private func heavy() async throws -> (url: URL, model: String) {
        if !app.engine.state.isRunning {
            if case .starting = app.engine.state {} else {
                guard app.canStart else { throw Zip.Failure(L("Download eerst een model onder Modellen.")) }
                app.startEngine()
            }
            try await wait(app.engine)
        }
        return (app.engine.baseURL, app.engine.model?.id ?? app.selectedModelID)
    }

    private func startFast(_ small: ModelInfo) async throws {
        if fast.state.isRunning, fast.model?.id == small.id { return }
        if fast.model?.id != small.id { await fast.stopAndWait() }
        if case .starting = fast.state {} else {
            let shards = app.models.shardURLs(small)
            let index = try GGUFIndex.load(shards: shards, sizes: small.files.map(\.size))
            // the memory that is left next to the heavy model
            let s = app.system
            let taken = app.plan?.resident ?? 0
            let rest = SystemInfo(chip: s.chip, physicalMemory: s.physicalMemory - min(taken, s.physicalMemory),
                                  performanceCores: s.performanceCores, gpuWorkingSet: s.effectiveGPULimit - min(taken, s.effectiveGPULimit),
                                  wiredLimitMB: 0, freeDisk: s.freeDisk)
            let plan = MemoryPlanner.plan(index: index, system: rest, contextSize: DocumentModels.fastContext, vision: false)
            fast.start(model: small, shards: shards, plan: plan, vision: nil)
        }
        try await wait(fast)
    }

    private func wait(_ engine: EngineController) async throws {
        while true {
            try Task.checkCancellation()
            switch engine.state {
            case .running: return
            case .failed(let why): throw Zip.Failure(why)
            case .stopped: throw Zip.Failure(L("De engine is gestopt."))
            case .starting: try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

/// One call to a local model, with the answer as it comes. Without tools: a page from the web can only be read here.
enum LocalModel {
    struct Result {
        var text = ""
        var cutOff = false
        var tokensPerSecond: Double?
    }

    /// `thinking`: how many tokens the model may think first; 0 is none. Thinking takes most of the time of a piece of
    /// writing (measured on Qwen3.8: 1,400 tokens for an answer of 150), so only what needs weighing gets it.
    static func complete(url: URL, model: String, system: String, user: String, thinking: Int = 0, maxTokens: Int = 4096,
                         temperature: Double = 0.3, onText: (String) -> Void = { _ in }) async throws -> Result {
        let s = Settings.shared
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": true,
            "temperature": temperature,
            // the thinking counts too
            "max_tokens": maxTokens + thinking,
            "chat_template_kwargs": ["enable_thinking": thinking > 0],
        ]
        if thinking > 0 {
            body["thinking_budget_tokens"] = thinking
            body["reasoning_budget_message"] = "\n\n" + L("Genoeg nagedacht; nu schrijf ik het antwoord.") + "\n"
        }
        var req = URLRequest(url: url.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !s.apiKey.isEmpty { req.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var message = ""
            for try await line in bytes.lines { message += line }
            throw Zip.Failure(L("Engine gaf \(http.statusCode): \(String(message.prefix(300)))"))
        }
        var result = Result()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let t = json["timings"] as? [String: Any] { result.tokensPerSecond = t["predicted_per_second"] as? Double }
            guard let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
            if choice["finish_reason"] as? String == "length" { result.cutOff = true }
            if let piece = (choice["delta"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                result.text += piece
                onText(result.text)
            }
        }
        return result
    }
}

/// What is taken out of a question before it goes to a search engine.
enum SearchQuery {
    private static let money = "(?:euro|eur|mln|miljoen|mld|miljard|k€|dollar|usd)"
    private static let patterns = [
        Rx("\\b[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+\\b"),                                            // e-mail
        Rx("\\b[A-Z]{2}\\d{2}\\s?(?:[A-Z0-9]{4}\\s?){2,7}[A-Z0-9]{1,4}\\b"),                      // IBAN
        Rx("(?:[€$£]\\s?\\d[\\d.,]*(?:\\s?\(money))?|\\b\\d[\\d.,]*\\s?\(money)\\b(?:\\s?\(money)\\b)?)", .caseInsensitive),
        Rx("(?<!\\w)(?:\\+|00)\\d{2}[\\s-]?(?:\\(0\\))?[\\s-]?\\d(?:[\\s-]?\\d){7,9}\\b|\\b0\\d{1,3}[\\s-]?\\d(?:[\\s-]?\\d){5,7}\\b"),   // phone
        Rx("\\b\\d{9}\\b"),                                                                        // BSN
        Rx("\\b\\d[\\d.,]{5,}\\d\\b"),                                                             // other long numbers
    ]

    /// The question without e-mail addresses, bank and phone numbers, amounts, long numbers and the `sensitive` terms
    /// (the client, the author). Years and article numbers stay.
    static func clean(_ query: String, sensitive: [String] = []) -> String {
        var out = query
        for p in patterns { out = p.replace(out) { _ in " " } }
        for term in sensitive.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: term.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !escaped.isEmpty else { continue }
            out = Rx("(?<!\\w)" + escaped + "(?!\\w)", .caseInsensitive).replace(out) { _ in " " }
        }
        out = Rx("\\s+([,.;:])").replace(out) { $0.first ?? "" }
        return Rx("\\s{2,}").replace(out) { _ in " " }.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\n\t"))
    }
}

/// The source references of a researched text: the code, not the model, makes the list of sources.
enum Citations {
    struct Source: Equatable {
        var title: String
        var url: String
    }

    private static let reference = Rx("\\[(\\d{1,3}(?:\\s*,\\s*\\d{1,3})*)\\](?!\\()")

    /// Numbers the sources in the order the text uses them, drops references to what does not exist, and adds the list.
    /// `unknown`: the numbers the model made up.
    static func finish(_ text: String, sources: [Source], heading: String, consulted: String) -> (markdown: String, unknown: [Int], cited: Int) {
        var order: [Int] = []
        var unknown: [Int] = []
        func numbers(_ m: Rx.Match) -> [Int] {
            (m.first ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        for m in reference.matches(text) {
            for n in numbers(m) {
                if n >= 1 && n <= sources.count {
                    if !order.contains(n) { order.append(n) }
                } else if !unknown.contains(n) {
                    unknown.append(n)
                }
            }
        }
        let renumbered = reference.replace(text) { m in
            let known = numbers(m).compactMap { n in order.firstIndex(of: n).map { $0 + 1 } }
            return known.isEmpty ? "" : "[" + known.map(String.init).joined(separator: ", ") + "]"
        }
        let listed = order.isEmpty ? Array(sources.indices.map { $0 + 1 }) : order
        let list = listed.enumerated().map { i, n in
            "\(i + 1). [\(sources[n - 1].title.replacingOccurrences(of: "]", with: ")"))](\(sources[n - 1].url)) (\(consulted))"
        }
        let clean = Rx("[ \\t]+([.,;:])").replace(renumbered) { $0.first ?? "" }.trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean + "\n\n# " + heading + "\n\n" + list.joined(separator: "\n") + "\n", unknown, order.count)
    }
}

/// The sections of a Markdown draft, to work on one at a time.
enum DraftSections {
    struct Section {
        let title: String
        let level: Int
        /// The whole section with its heading, up to the next heading.
        let range: NSRange
        /// What follows the heading.
        let bodyRange: NSRange
        /// A lower heading follows directly: only a short introduction belongs here.
        var hasChildren = false
    }

    private static let heading = Rx("^(#{1,6})[ \\t]+(.+?)[ \\t]*#*[ \\t]*$", .anchorsMatchLines)
    private static let fence = Rx("^ {0,3}(```|~~~)", .anchorsMatchLines)

    static func list(_ text: String) -> [Section] {
        let ns = text as NSString
        let fences = fence.matches(text).map(\.range.location)
        // a line that starts with # inside a code block is no heading
        func inCode(_ at: Int) -> Bool { fences.filter { $0 < at }.count % 2 == 1 }
        let heads = heading.matches(text).filter { !inCode($0.range.location) }
        var out: [Section] = []
        for (i, m) in heads.enumerated() {
            let end = i + 1 < heads.count ? heads[i + 1].range.location : ns.length
            let bodyStart = min(m.range.location + m.range.length, end)
            let level = m.groups[0]?.count ?? 1
            var s = Section(title: m.groups[1] ?? "", level: level,
                            range: NSRange(location: m.range.location, length: end - m.range.location),
                            bodyRange: NSRange(location: bodyStart, length: end - bodyStart))
            if i + 1 < heads.count, (heads[i + 1].groups[0]?.count ?? 1) > level { s.hasChildren = true }
            out.append(s)
        }
        return out
    }

    /// What an action works on: the selection, else the section around the cursor, else everything after the fields.
    static func scope(in text: String, selection: NSRange) -> NSRange {
        let ns = text as NSString
        if selection.length > 0, selection.location + selection.length <= ns.length { return selection }
        if let s = list(text).last(where: { $0.range.location <= selection.location }) { return s.range }
        let start = ns.length - (DocumentDraft(markdown: text).body as NSString).length
        return NSRange(location: max(0, start), length: ns.length - max(0, start))
    }

    /// The model's answer without a Markdown fence around it or a heading it was told not to write.
    static func cleaned(_ answer: String, removingHeading: String? = nil) -> String {
        var t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            var lines = t.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            t = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let removingHeading, let first = t.components(separatedBy: "\n").first, first.hasPrefix("#"),
           DocxFields.normalized(first).hasSuffix(DocxFields.normalized(removingHeading)) {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// A section's text must bring no headings along: the sections are counted, and the draft's structure is the template's.
    static func withoutHeadings(_ text: String) -> String {
        heading.replace(text) { "**" + ($0.groups[1] ?? "") + "**" }
    }
}
