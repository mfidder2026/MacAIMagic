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
                let (hits, notice) = try await searchNoting(q)
                let note = notice.map { $0 + "\n\n" } ?? ""
                if hits.isEmpty { return Result(text: note + "No results for \"\(q)\".", sources: []) }
                let text = note + hits.enumerated().map { i, h in "[\(i + 1)] \(h.title)\n\(h.url)\n\(h.snippet)" }.joined(separator: "\n\n")
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
        case "web_search": return L("Zoeken: \(args["query"] as? String ?? "")")
        case "fetch_url": return L("Lezen: \(URL(string: args["url"] as? String ?? "")?.host ?? "…")")
        default: return call.name
        }
    }

    // MARK: - search

    struct Hit { var title: String; var url: String; var snippet: String }

    static func search(_ query: String) async throws -> [Hit] { try await searchNoting(query).hits }

    /// A failing Brave is said out loud (no "no results"), and DuckDuckGo takes over.
    private static func searchNoting(_ query: String) async throws -> (hits: [Hit], notice: String?) {
        let key = Settings.shared.braveKey
        var notice: String?
        if !key.isEmpty {
            do { return (try await brave(query, key: key), nil) }
            catch is CancellationError { throw CancellationError() }
            catch { notice = L("Brave Search gaf een fout (\(error.localizedDescription)); er wordt gezocht met DuckDuckGo.") }
        }
        return (try await SearchRoute.shared.search(query, primary: duckDuckGo, fallback: bing), notice)
    }

    /// The search region follows the language of the app.
    static func duckDuckGoRegion(_ language: String) -> String {
        switch language { case "nl": "nl-nl"; case "de": "de-de"; case "fr": "fr-fr"; default: "us-en" }
    }

    static func bingRegion(_ language: String) -> (language: String, country: String) {
        switch language { case "nl": ("nl", "NL"); case "de": ("de", "DE"); case "fr": ("fr", "FR"); default: ("en", "US") }
    }

    /// DuckDuckGo answers with a page for bots after a few quick searches; that is no empty result.
    struct Blocked: LocalizedError {
        var errorDescription: String? { L("De zoekmachines weigeren nu; probeer het straks opnieuw of vul onder Instellingen een Brave-sleutel in.") }
    }

    static func isBlocked(status: Int, html: String) -> Bool {
        status == 202 || status == 403 || status == 429 || html.contains("anomaly-modal") || html.contains("bots use DuckDuckGo")
    }

    /// Brave Search API, when the user has a key (more reliable than scraping).
    private static func brave(_ query: String, key: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "8")]
        var req = URLRequest(url: c.url!)
        req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status == 200 else { throw NSError(domain: "Brave", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]) }
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
        req.httpBody = Data("q=\(q)&kl=\(duckDuckGoRegion(Settings.shared.language))".utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        if isBlocked(status: (response as? HTTPURLResponse)?.statusCode ?? 200, html: html) { throw Blocked() }
        return parseDuckDuckGo(html)
    }

    /// Bing, for when DuckDuckGo refuses.
    private static func bing(_ query: String) async throws -> [Hit] {
        var c = URLComponents(string: "https://www.bing.com/search")!
        let region = bingRegion(Settings.shared.language)
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "setlang", value: region.language), URLQueryItem(name: "cc", value: region.country)]
        var req = URLRequest(url: c.url!)
        req.setValue(HTML.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if isBlocked(status: (response as? HTTPURLResponse)?.statusCode ?? 200, html: "") { throw Blocked() }
        return parseBing(String(decoding: data, as: UTF8.self))
    }

    private static let bingResult = Rx("<li class=\"b_algo\".*?<h2[^>]*>\\s*<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", .dotMatchesLineSeparators)

    static func parseBing(_ html: String) -> [Hit] {
        bingResult.matches(html).prefix(8).compactMap { m in
            guard let href = m.groups[0], let title = m.groups[1], let url = bingTarget(HTML.decodeEntities(href)) else { return nil }
            let name = HTML.text(from: title)
            return Hit(title: name.isEmpty ? url : name, url: url, snippet: "")
        }
    }

    /// Result links go through a redirect, with the target in base64 after "a1" in the parameter u.
    static func bingTarget(_ link: String) -> String? {
        guard let c = URLComponents(string: link), c.host?.hasSuffix("bing.com") == true else {
            return link.hasPrefix("http") ? link : nil
        }
        guard var coded = c.queryItems?.first(where: { $0.name == "u" })?.value, coded.hasPrefix("a1") else { return nil }
        coded = String(coded.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        coded += String(repeating: "=", count: (4 - coded.count % 4) % 4)
        guard let data = Data(base64Encoded: coded), let target = String(data: data, encoding: .utf8), target.hasPrefix("http") else { return nil }
        return target
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

/// Which search engine to ask: not too quickly after each other, and after a refusal the other one for a while.
actor SearchRoute {
    static let shared = SearchRoute()
    private let spacing: TimeInterval
    private let pause: TimeInterval
    private var last = Date.distantPast
    private var refusedUntil = Date.distantPast

    init(spacing: TimeInterval = 2, pause: TimeInterval = 600) {
        self.spacing = spacing
        self.pause = pause
    }

    func search(_ query: String, primary: @Sendable (String) async throws -> [WebTools.Hit],
                fallback: @Sendable (String) async throws -> [WebTools.Hit]) async throws -> [WebTools.Hit] {
        if Date() < refusedUntil { return try await fallback(query) }
        let wait = last.addingTimeInterval(spacing).timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        last = Date()
        do {
            let hits = try await primary(query)
            return hits.isEmpty ? try await fallback(query) : hits
        } catch is WebTools.Blocked {
            refusedUntil = Date().addingTimeInterval(pause)
            return try await fallback(query)
        } catch {
            if error is CancellationError { throw error }
            return try await fallback(query)
        }
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
