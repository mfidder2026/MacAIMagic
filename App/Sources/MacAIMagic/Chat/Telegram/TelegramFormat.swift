import Foundation

/// The model writes Markdown; Telegram takes a little HTML (b, i, code, pre, a) and at most 4096 characters a message.
enum TelegramFormat {
    /// Room for the HTML the conversion adds (&amp;, tags) under Telegram's 4096.
    static let limit = 3500

    /// Splits at a blank line, else at a line end, else at a space; a code block is not split when it fits.
    static func chunks(_ text: String, limit: Int = limit) -> [String] {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var out: [String] = []
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.range(of: "\n\n", options: .backwards)?.lowerBound
                ?? window.range(of: "\n", options: .backwards)?.lowerBound
                ?? window.range(of: " ", options: .backwards)?.lowerBound
            let end = cut.flatMap { rest.distance(from: rest.startIndex, to: $0) > limit / 3 ? $0 : nil } ?? window.endIndex
            var part = String(rest[..<end])
            rest = rest[end...].drop { $0 == "\n" || $0 == " " }
            // an open code block goes on in the next part
            if part.components(separatedBy: "```").count % 2 == 0 {
                part += "\n```"
                rest = "```\n" + rest
            }
            out.append(part)
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out.isEmpty ? [""] : out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Markdown to Telegram's HTML: code blocks, inline code, bold, italic, links, headings as bold. Everything else
    /// is escaped, so nothing the model writes can become a tag.
    static func html(_ markdown: String) -> String {
        var out = ""
        let parts = markdown.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                // a code block: drop the language on the first line
                var code = part
                if let nl = code.firstIndex(of: "\n"), !code[..<nl].contains(" ") { code = String(code[code.index(after: nl)...]) }
                out += "<pre>" + escape(code.trimmingCharacters(in: .newlines)) + "</pre>"
            } else {
                out += inline(part)
            }
        }
        return out
    }

    private static func inline(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return "<b>" + spans(title) + "</b>"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return "• " + spans(String(trimmed.dropFirst(2)))
            }
            return spans(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Inline code first (its content stays as it is), then links, bold and italic on the escaped rest.
    private static func spans(_ text: String) -> String {
        let pieces = text.components(separatedBy: "`")
        guard pieces.count % 2 == 1 else { return style(escape(text)) }
        return pieces.enumerated().map { i, p in i % 2 == 1 ? "<code>" + escape(p) + "</code>" : style(escape(p)) }.joined()
    }

    private static func style(_ s: String) -> String {
        var s = s
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^\s)"]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+?)\*(?![\w*])"#, with: "<i>$1</i>", options: .regularExpression)
        return s
    }
}
