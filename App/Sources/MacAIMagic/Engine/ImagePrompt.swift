import Foundation

/// Turns the user's description into one the image model follows well: in English, concrete and visual. The chat model
/// writes it, and may first look up on the web what something looks like (a building, a product, a style). What goes
/// to the search engine is cleaned as in the documents module.
enum ImagePrompt {
    static let maxRounds = 4

    static let instructions = """
        You write descriptions for an image model that draws what it reads. Rewrite the user's description as one English \
        paragraph of at most 80 words: the subject first, then what it looks like, the setting, the light and the style \
        (photo, painting, drawing). Keep everything the user asked for and add nothing they did not want. When the description \
        names something real whose look matters (a building, a place, a product, a person's public appearance, an art style) \
        and you are not sure what it looks like, use web_search and then fetch_url on the best result, at most a few times. \
        Describe it as the pages describe it: its material, colours, shape, towers or roofs. What you remember yourself may be \
        wrong; the pages go first, and leave out what they do not say. Answer with the description only: no title, no quotes, \
        no explanation.
        """

    struct Result { var prompt: String; var sources: [Source] }

    /// `send` posts one request and returns the decoded answer (tests stand in for the engine); `onStep` names what happens.
    static func improve(_ text: String, model: String, send: ([String: Any]) async throws -> [String: Any],
                        onStep: (String) -> Void) async throws -> Result {
        var messages: [[String: Any]] = [["role": "system", "content": instructions], ["role": "user", "content": text]]
        var sources: [Source] = []
        for round in 0...maxRounds {
            var body: [String: Any] = [
                "model": model, "messages": messages, "stream": false, "temperature": 0.3, "max_tokens": 400,
                "chat_template_kwargs": ["enable_thinking": false], "thinking_budget_tokens": 0,
            ]
            // the last round may only answer
            if round < maxRounds { body["tools"] = WebTools.definitions } else { body["tool_choice"] = "none" }
            let answer = try await send(body)
            guard let message = (answer["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { break }
            let calls = (message["tool_calls"] as? [[String: Any]]) ?? []
            if calls.isEmpty {
                let prompt = cleaned(message["content"] as? String ?? "")
                return Result(prompt: prompt.isEmpty ? text : prompt, sources: sources)
            }
            messages.append(["role": "assistant", "content": message["content"] as? String ?? "", "tool_calls": calls])
            for call in calls {
                let function = call["function"] as? [String: Any] ?? [:]
                var tool = ToolCall(id: call["id"] as? String ?? UUID().uuidString, name: function["name"] as? String ?? "",
                                    arguments: function["arguments"] as? String ?? "{}")
                if tool.name == "web_search",
                   var args = (try? JSONSerialization.jsonObject(with: Data(tool.arguments.utf8))) as? [String: Any],
                   let query = args["query"] as? String {
                    args["query"] = SearchQuery.clean(query)
                    tool.arguments = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
                }
                onStep(WebTools.label(for: tool))
                let out = await WebTools.run(tool)
                for s in out.sources where !sources.contains(where: { $0.url == s.url }) { sources.append(s) }
                messages.append(["role": "tool", "tool_call_id": tool.id, "content": String(out.text.prefix(6000))])
            }
            onStep(L("Beschrijving schrijven…"))
        }
        return Result(prompt: text, sources: sources)
    }

    /// The description alone: no quotes, no label in front, no thinking left behind.
    static func cleaned(_ answer: String) -> String {
        var s = answer
        if let end = s.range(of: "</think>") { s = String(s[end.upperBound...]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for label in ["Description:", "Prompt:", "Image description:"] where s.lowercased().hasPrefix(label.lowercased()) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.count > 1, let f = s.first, let l = s.last, "\"'“”".contains(f), "\"'“”".contains(l) { s = String(s.dropFirst().dropLast()) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
