import Foundation

/// Turns the user's description into one the image model follows well: in English, concrete and visual. The chat model
/// writes it, and may first look up on the web what something looks like (a building, a product, a style). What goes
/// to the search engine is cleaned as in the documents module.
enum ImagePrompt {
    static let maxRounds = 4

    /// Measured on the Eiffel Tower: a long Dutch description full of facts (324 metres, rivets, "a roof") drew a tower that
    /// does not exist; "A photograph of the Eiffel Tower in Paris" drew the real one. The image model knows famous things by
    /// their English name, reads English best, and draws every word it gets.
    static let instructions = """
        You write the description an image model draws from. The image model reads English only and draws every word, so: \
        write in English, whatever language the user wrote in. Start with what kind of picture it is and the subject by its \
        common English name ("A photograph of the Eiffel Tower in Paris"). Then add only what can be seen: the view, the \
        setting, the light, the colours, the style. No measurements, dates, history, materials or how it was built, and no \
        details you are not sure of: a wrong detail ends up in the picture. Keep everything the user asked for. At most 60 \
        words, one paragraph. Never describe the shape or parts of a real, named thing from memory: such details are often \
        wrong, and a wrong detail ends up in the picture. When the request names a real place, building, landmark, product or \
        artwork, first use web_search and read one good page with fetch_url, then describe in a few words what the pages say \
        it looks like (its shape, colours and surroundings). If they say nothing about its look, give only its name and the \
        scene. Answer with the description only: no title, no quotes, \
        no explanation.
        """

    struct Result { var prompt: String; var sources: [Source] }

    /// Pages of photos without text: they say nothing about what a thing looks like.
    static let picturesOnly = ["alamy.", "dreamstime.", "shutterstock.", "gettyimages.", "istockphoto.", "pinterest.", "depositphotos.",
                               "123rf.", "adobe.com", "unsplash.", "pexels.", "flickr."]

    /// The search hits to read when the model searched but read nothing: the first page with text (often the place's own,
    /// which says most about its look) and an encyclopedia.
    static func pagesToRead(_ hits: [Source]) -> [Source] {
        let readable = hits.filter { hit in !picturesOnly.contains { hit.url.contains($0) } }
        let own = readable.first { !$0.url.contains("wikipedia.org") }
        let encyclopedia = readable.first { $0.url.contains("wikipedia.org") }
        return [own, encyclopedia].compactMap { $0 }
    }

    /// `send` posts one request and returns the decoded answer (tests stand in for the engine); `onStep` names what happens;
    /// `fetch` reads a page (tests stand in for the web).
    static func improve(_ text: String, model: String, send: ([String: Any]) async throws -> [String: Any],
                        fetch: (String) async -> String? = { url in try? await WebTools.fetch(url).1 },
                        onStep: (String) -> Void) async throws -> Result {
        var searchHits: [Source] = []
        var readPage = false
        var forcedRead = false
        var messages: [[String: Any]] = [["role": "system", "content": instructions],
                                         ["role": "user", "content": "The user's request:\n\(text)\n\nWrite the English description now."]]
        var sources: [Source] = []
        for round in 0...(maxRounds + 1) {
            var body: [String: Any] = [
                "model": model, "messages": messages, "stream": false, "temperature": 0.3, "max_tokens": 400,
                "chat_template_kwargs": ["enable_thinking": false], "thinking_budget_tokens": 0,
            ]
            // the last round may only answer
            if round < maxRounds && !forcedRead { body["tools"] = WebTools.definitions } else { body["tool_choice"] = "none" }
            let answer = try await send(body)
            guard let message = (answer["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { break }
            let calls = (message["tool_calls"] as? [[String: Any]]) ?? []
            if calls.isEmpty {
                var prompt = cleaned(message["content"] as? String ?? "")
                // it searched but read no page, so its description came from memory: the app reads the best hit and asks again
                if !readPage && !forcedRead {
                    var pages: [String] = []
                    for page in pagesToRead(searchHits) {
                        onStep(label(ToolCall(id: "", name: "fetch_url", arguments: "{\"url\": \"\(page.url)\"}")))
                        guard let body = await fetch(page.url), !body.isEmpty else { continue }
                        pages.append("<<<\n" + String(body.prefix(2500)) + "\n>>>")
                        if !sources.contains(where: { $0.url == page.url }) { sources.append(page) }
                    }
                    if !pages.isEmpty {
                        forcedRead = true
                        readPage = true
                        messages.append(["role": "assistant", "content": prompt])
                        messages.append(["role": "user", "content": "Here are pages about it. Rewrite the description so that what it says about the look of the subject (its shape, colours, towers, roofs, material as it looks) comes from these pages, not from memory. Leave out what they do not say. Keep the subject's name in the first words. English, at most 60 words, the description only.\n\n" + pages.joined(separator: "\n\n")])
                        continue
                    }
                }
                // a small model answers in the user's language now and then: once more, in English
                if !prompt.isEmpty && !isEnglish(prompt) {
                    onStep(L("schrijft het opnieuw, in het Engels"))
                    messages.append(["role": "assistant", "content": prompt])
                    messages.append(["role": "user", "content": "That is not English. Write the same description in English, at most 60 words."])
                    var again = body
                    again["messages"] = messages
                    again["tools"] = nil
                    again["tool_choice"] = "none"
                    let retry = try await send(again)
                    let second = cleaned((((retry["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String) ?? "")
                    if !second.isEmpty { prompt = second }
                }
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
                onStep(label(tool))
                let out = await WebTools.run(tool)
                if tool.name == "web_search" { searchHits = out.sources } else if tool.name == "fetch_url" { readPage = true }
                for s in out.sources where !sources.contains(where: { $0.url == s.url }) { sources.append(s) }
                // the fast model has a context of 16K: a page is cut to what fits a few times
                messages.append(["role": "tool", "tool_call_id": tool.id, "content": String(out.text.prefix(3000))])
            }
        }
        return Result(prompt: text, sources: sources)
    }

    /// What the model does, after its name: "zoekt: Rijksmuseum", "leest: rijksmuseum.nl".
    static func label(_ call: ToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "web_search": return L("zoekt: \(args["query"] as? String ?? "")")
        case "fetch_url": return L("leest: \(URL(string: args["url"] as? String ?? "")?.host?.replacingOccurrences(of: "www.", with: "") ?? "…")")
        default: return call.name
        }
    }

    /// More English little words than Dutch, German or French ones.
    static func isEnglish(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        let english: Set<String> = ["the", "a", "an", "of", "with", "and", "in", "on", "at", "its", "is", "from", "by"]
        let other: Set<String> = ["de", "het", "een", "van", "met", "en", "op", "bij", "die", "dat", "zijn", "der", "das", "und", "mit",
                                  "ein", "eine", "auf", "le", "la", "les", "une", "des", "avec", "et", "du", "sur"]
        let e = words.filter(english.contains).count, o = words.filter(other.contains).count
        return e >= o
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
