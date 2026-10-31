import Foundation

/// The tools the model can call: web search and reading a page. They run in the app, not in the engine.
enum WebTools {
    static let definitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current information. Returns titles, URLs and snippets. Use it for news, facts that may have changed, prices, documentation, or anything you are not sure about.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"],
                    ],
                    "required": ["query"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "fetch_url",
                "description": "Read a web page and return its main text. Use it after web_search to read a result in full.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The http(s) URL to read"],
                    ],
                    "required": ["url"],
                ],
            ],
        ],
    ]

    struct Result { var text: String; var sources: [Source] }

    static func run(_ call: ToolCall) async -> Result {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        do {
            switch call.name {
            case "web_search":
                let q = args["query"] as? String ?? ""
                let hits = try await search(q)
                if hits.isEmpty { return Result(text: "No results for \"\(q)\".", sources: []) }
                let text = hits.enumerated().map { i, h in "[\(i + 1)] \(h.title)\n\(h.url)\n\(h.snippet)" }.joined(separator: "\n\n")
                return Result(text: text, sources: hits.map { Source(title: $0.title, url: $0.url) })
            case "fetch_url":
                let u = args["url"] as? String ?? ""
                let (title, body) = try await fetch(u)
                return Result(text: "# \(title)\n\(body)", sources: [Source(title: title, url: u)])
            default:
                return Result(text: "Unknown tool \(call.name)", sources: [])
            }
        } catch {
            return Result(text: "Tool error: \(error.localizedDescription)", sources: [])
        }
    }

    static func label(for call: ToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "web_search": return "Zoeken: \(args["query"] as? String ?? "")"
        case "fetch_url": return "Lezen: \(URL(string: args["url"] as? String ?? "")?.host ?? "pagina")"
        default: return call.name
        }
    }

    // MARK: - search

    struct Hit { var title: String; var url: String; var snippet: String }

    static func search(_ query: String) async throws -> [Hit] {
        let key = Settings.shared.braveKey
        return key.isEmpty ? try await duckDuckGo(query) : try await brave(query, key: key)
    }

    /// Brave Search API, when the user has a key (more reliable than scraping).
    private static func brave(_ query: String, key: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "8")]
        var req = URLRequest(url: c.url!)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = ((json?["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return results.map {
            Hit(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "",
                snippet: HTML.text(from: $0["description"] as? String ?? ""))
        }
    }

    /// DuckDuckGo's HTML endpoint: no key needed.
    private static func duckDuckGo(_ query: String) async throws -> [Hit] {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(HTML.userAgent, forHTTPHeaderField: "User-Agent")
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        req.httpBody = Data("q=\(q)&kl=nl-nl".utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        return parseDuckDuckGo(html)
    }

    static func parseDuckDuckGo(_ html: String) -> [Hit] {
        var hits: [Hit] = []
        let blocks = html.components(separatedBy: "class=\"result__a\"").dropFirst()
        for block in blocks.prefix(8) {
            guard let hrefRange = block.range(of: "href=\"") else { continue }
            let afterHref = block[hrefRange.upperBound...]
            guard let hrefEnd = afterHref.firstIndex(of: "\"") else { continue }
            var url = HTML.decodeEntities(String(afterHref[..<hrefEnd]))
            // result links go through a redirect: //duckduckgo.com/l/?uddg=<target>
            if let c = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
               let target = c.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = target
            }
            let titleHTML = afterHref[hrefEnd...].dropFirst().split(separator: "<", maxSplits: 1).first.map(String.init) ?? ""
            let title = HTML.text(from: String(titleHTML.drop(while: { $0 != ">" }).dropFirst()))
            var snippet = ""
            if let s = block.range(of: "class=\"result__snippet\"") {
                let rest = block[s.upperBound...]
                if let gt = rest.firstIndex(of: ">"), let end = rest.range(of: "</a>") {
                    snippet = HTML.text(from: String(rest[rest.index(after: gt)..<end.lowerBound]))
                }
            }
            if url.hasPrefix("http") && !url.contains("duckduckgo.com/y.js") {
                hits.append(Hit(title: title.isEmpty ? url : title, url: url, snippet: snippet))
            }
        }
        return hits
    }

    // MARK: - fetch

    static func fetch(_ urlString: String) async throws -> (String, String) {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.setValue(HTML.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let raw = String(decoding: data.prefix(3 << 20), as: UTF8.self)
        if !type.contains("html") {
            return (url.lastPathComponent, String(raw.prefix(12_000)))
        }
        let title = HTML.title(raw) ?? url.host ?? urlString
        // keep the context small: the model's prompt reading is the slow part on a Mac
        return (title, String(HTML.text(from: HTML.mainContent(raw)).prefix(12_000)))
    }
}

/// Just enough HTML handling to turn pages into readable text.
enum HTML {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func title(_ html: String) -> String? {
        guard let r = html.range(of: "<title[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let e = html.range(of: "</title>", options: .caseInsensitive, range: r.upperBound..<html.endIndex) else { return nil }
        return text(from: String(html[r.upperBound..<e.lowerBound]))
    }

    /// The <article> or <main> when the page has one, else the <body>.
    static func mainContent(_ html: String) -> String {
        for tag in ["article", "main", "body"] {
            if let r = html.range(of: "<\(tag)[\\s>]", options: [.regularExpression, .caseInsensitive]),
               let e = html.range(of: "</\(tag)>", options: [.caseInsensitive, .backwards]), e.lowerBound > r.upperBound {
                return String(html[r.lowerBound..<e.lowerBound])
            }
        }
        return html
    }

    static func text(from html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form", "aside"] {
            s = s.replacingOccurrences(of: "<\(tag)[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t\\u00a0]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&hellip;": "…"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out.replacingOccurrences(of: "&#(\\d+);", with: "", options: .regularExpression)
    }
}
