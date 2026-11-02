import Foundation

struct MDInline: Equatable {
    var text = ""
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: String?
    var isBreak = false
    /// An image in the text: `text` is its description.
    var imageSource: String?
}

/// One block of a Markdown document, ready to become OOXML.
struct MDBlock {
    enum Kind { case heading, paragraph, list, table, code, quote, image, pageBreak, caption }

    var kind: Kind
    var inlines: [MDInline] = []
    var level = 0
    var ordered = false
    var listID = 0
    var header: [[MDInline]] = []
    var rows: [[[MDInline]]] = []
    var text = ""
    var source = ""

    var plain: String { inlines.map(\.text).joined() }
}

/// The Markdown models and people write: headings, lists, tables, quotes, code, images, links and emphasis.
enum MarkdownBlocks {
    private static let pageBreak = Rx("<!--\\s*(pagebreak|page-break|nieuwe pagina)\\s*-->|\\\\(newpage|pagebreak)", .caseInsensitive)
    private static let heading = Rx("^ {0,3}(#{1,6})[ \\t]+(.*?)[ \\t]*#*[ \\t]*$")
    private static let fence = Rx("^ {0,3}(```+|~~~+)")
    private static let rule = Rx("^ {0,3}([-*_])[ \\t]*(\\1[ \\t]*){2,}$")
    private static let listItem = Rx("^([ \\t]*)([-*+]|\\d{1,9}[.)])[ \\t]+(.*)$")
    private static let tableDelimiter = Rx("^[ \\t]*\\|?[ \\t]*:?-+:?[ \\t]*(\\|[ \\t]*:?-+:?[ \\t]*)*\\|?[ \\t]*$")
    private static let captionLine = Rx("^(figuur|figure|afbeelding|tabel|table)\\s+\\d+[:.]", .caseInsensitive)

    static func parse(_ source: String) -> [MDBlock] {
        let text = pageBreak.replace(source.replacingOccurrences(of: "\r\n", with: "\n")) { _ in "\n\n<!-- pagebreak -->\n\n" }
        let lines = text.components(separatedBy: "\n")
        var out: [MDBlock] = []
        var listCount = 0
        var i = 0

        func startsBlock(_ line: String) -> Bool {
            heading.test(line) || fence.test(line) || listItem.test(line) || line.hasPrefix(">") || line.hasPrefix("<!--")
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            if let m = fence.first(line), let marker = m.groups[0] {
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(MDBlock(kind: .code, text: code.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("<!--") {
                var comment = trimmed
                while !comment.contains("-->"), i + 1 < lines.count {
                    i += 1
                    comment += "\n" + lines[i]
                }
                i += 1
                if comment.contains("pagebreak") { out.append(MDBlock(kind: .pageBreak)) }
                continue
            }
            if let m = heading.first(line) {
                out.append(MDBlock(kind: .heading, inlines: inlines(m.groups[1] ?? ""), level: m.groups[0]?.count ?? 1))
                i += 1
                continue
            }
            if rule.test(line) { i += 1; continue }
            if line.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    quoted.append(String(lines[i].dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                for part in quoted.split(separator: "", omittingEmptySubsequences: true) {
                    out.append(MDBlock(kind: .quote, inlines: inlines(part.joined(separator: " "))))
                }
                continue
            }
            if i + 1 < lines.count, line.contains("|"), lines[i + 1].contains("-"), tableDelimiter.test(lines[i + 1]) {
                var table = MDBlock(kind: .table, header: cells(line).map(inlines))
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    table.rows.append(cells(lines[i]).map(inlines))
                    i += 1
                }
                out.append(table)
                continue
            }
            if listItem.test(line) {
                parseList(lines, &i, &out, &listCount)
                continue
            }
            var para = [line.trimmingCharacters(in: .whitespaces)]
            var hardBreaks = [line.hasSuffix("  ") || line.hasSuffix("\\")]
            i += 1
            var setext = 0
            while i < lines.count {
                let next = lines[i]
                let t = next.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || startsBlock(next) { break }
                if para.count == 1, !t.isEmpty, t.allSatisfy({ $0 == "=" }) { setext = 1; i += 1; break }
                if para.count == 1, t.count >= 2, t.allSatisfy({ $0 == "-" }) { setext = 2; i += 1; break }
                if rule.test(next) { break }
                para.append(t)
                hardBreaks.append(next.hasSuffix("  ") || next.hasSuffix("\\"))
                i += 1
            }
            if setext > 0 {
                out.append(MDBlock(kind: .heading, inlines: inlines(para[0]), level: setext))
                continue
            }
            var parts: [MDInline] = []
            for (n, p) in para.enumerated() {
                let clean = p.hasSuffix("\\") ? String(p.dropLast()) : p
                parts += inlines(clean)
                if n < para.count - 1 { parts.append(hardBreaks[n] ? MDInline(isBreak: true) : MDInline(text: " ")) }
            }
            addParagraph(merge(parts), &out)
        }
        return out
    }

    private static func addParagraph(_ parts: [MDInline], _ out: inout [MDBlock]) {
        let images = parts.filter { $0.imageSource != nil }
        let rest = parts.filter { $0.imageSource == nil }
        let plain = rest.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty {
            let isCaption = captionLine.test(plain) && [MDBlock.Kind.image, .table].contains(out.last?.kind)
            out.append(MDBlock(kind: isCaption ? .caption : .paragraph, inlines: rest))
        }
        for im in images { out.append(MDBlock(kind: .image, text: im.text, source: im.imageSource ?? "")) }
    }

    private static func parseList(_ lines: [String], _ i: inout Int, _ out: inout [MDBlock], _ listCount: inout Int) {
        var stack: [(indent: Int, ordered: Bool, id: Int)] = []
        while i < lines.count {
            let line = lines[i]
            if let m = listItem.first(line) {
                let indent = (m.groups[0] ?? "").replacingOccurrences(of: "\t", with: "    ").count
                let marker = m.groups[1] ?? "-"
                let ordered = marker.first?.isNumber == true
                while let top = stack.last, indent < top.indent { stack.removeLast() }
                if let top = stack.last, indent == top.indent, top.ordered != ordered { stack.removeLast() }
                if stack.isEmpty || indent > stack[stack.count - 1].indent + 1 {
                    listCount += 1
                    stack.append((indent, ordered, listCount))
                }
                let top = stack[stack.count - 1]
                out.append(MDBlock(kind: .list, inlines: inlines(m.groups[2] ?? ""), level: stack.count - 1, ordered: top.ordered, listID: top.id))
                i += 1
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                // a blank line ends the list unless more of it follows
                var next = i + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                guard next < lines.count else { i = next; return }
                let after = lines[next]
                if listItem.test(after) { i = next; continue }
                if after.hasPrefix("  ") || after.hasPrefix("\t") {
                    out[out.count - 1].inlines += [MDInline(isBreak: true)] + inlines(after.trimmingCharacters(in: .whitespaces))
                    i = next + 1
                    continue
                }
                i = next
                return
            }
            // a continuation line of the item, unless another kind of block starts
            if heading.test(line) || fence.test(line) || line.hasPrefix(">") || line.hasPrefix("<!--") || line.contains("|") { return }
            out[out.count - 1].inlines = merge(out[out.count - 1].inlines + [MDInline(text: " ")] + inlines(t))
            i += 1
        }
    }

    /// The cells of a table row; \| is a | in a cell.
    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cell = ""
        var escaped = false
        for c in t {
            if escaped {
                cell.append(c == "|" ? "|" : "\\\(c)")
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "|" {
                out.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(c)
            }
        }
        if escaped { cell.append("\\") }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        return out
    }

    // MARK: - inlines

    private static let breakTag = Rx("^<br\\s*/?>", .caseInsensitive)
    private static let autolink = Rx("^<(https?://[^>\\s]+)>")
    private static let htmlTag = Rx("^</?[a-zA-Z!][^>]*>")

    static func inlines(_ text: String) -> [MDInline] {
        merge(scan(Array(text), MDInline()))
    }

    private static func scan(_ c: [Character], _ style: MDInline) -> [MDInline] {
        var out: [MDInline] = []
        var plain = ""
        func flush() {
            guard !plain.isEmpty else { return }
            var x = style
            x.text = plain
            out.append(x)
            plain = ""
        }
        func rest(_ i: Int) -> String { String(c[i...]) }
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                plain.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "`" {
                var n = 0
                while i + n < c.count, c[i + n] == "`" { n += 1 }
                if let end = closing(c, from: i + n, marker: String(repeating: "`", count: n)) {
                    flush()
                    var x = style
                    x.text = String(c[(i + n)..<end]).trimmingCharacters(in: .whitespaces)
                    x.code = true
                    out.append(x)
                    i = end + n
                    continue
                }
                plain.append(String(repeating: "`", count: n))
                i += n
                continue
            }
            if ch == "<" {
                let tail = rest(i)
                if let m = breakTag.first(tail) {
                    flush()
                    out.append(MDInline(isBreak: true))
                    i += (tail as NSString).substring(with: m.range).count
                    continue
                }
                if let m = autolink.first(tail), let url = m.groups[0] {
                    flush()
                    var x = style
                    x.text = url
                    x.link = url
                    out.append(x)
                    i += url.count + 2
                    continue
                }
                if let m = htmlTag.first(tail) {
                    flush()
                    i += (tail as NSString).substring(with: m.range).count
                    continue
                }
            }
            if ch == "!", i + 1 < c.count, c[i + 1] == "[", let (alt, target, end) = linkParts(c, from: i + 1) {
                flush()
                var x = MDInline(text: alt)
                x.imageSource = target
                out.append(x)
                i = end
                continue
            }
            if ch == "[", let (label, target, end) = linkParts(c, from: i) {
                flush()
                var inner = style
                inner.link = target
                out += scan(Array(label), inner)
                i = end
                continue
            }
            if ch == "*" || ch == "_" || ch == "~" {
                var n = 0
                while i + n < c.count, c[i + n] == ch { n += 1 }
                let wordInside = ch == "_" && i > 0 && (c[i - 1].isLetter || c[i - 1].isNumber)
                let opens = i + n < c.count && !c[i + n].isWhitespace && !wordInside
                if opens && (ch != "~" || n >= 2) {
                    let count = ch == "~" ? 2 : min(n, 3)
                    let marker = String(repeating: ch, count: count)
                    if let end = closing(c, from: i + count, marker: marker) {
                        flush()
                        var inner = style
                        if ch == "~" { inner.strike = true }
                        if count == 3 || count == 2 && ch != "~" { inner.bold = true }
                        if count == 3 || count == 1 { inner.italic = true }
                        out += scan(Array(c[(i + count)..<end]), inner)
                        i = end + count
                        continue
                    }
                }
                plain.append(String(repeating: ch, count: n))
                i += n
                continue
            }
            plain.append(ch)
            i += 1
        }
        flush()
        return out
    }

    /// Where `marker` closes, not right after a space.
    private static func closing(_ c: [Character], from: Int, marker: String) -> Int? {
        let m = Array(marker)
        guard from < c.count, c.count >= m.count else { return nil }
        var i = from
        while i + m.count <= c.count {
            if c[i] == "\\" { i += 2; continue }
            if Array(c[i..<(i + m.count)]) == m {
                let single = m[0] != "`"
                let next = i + m.count
                // ** must not close on the first two stars of ***
                if single, next < c.count, c[next] == m[0], m.count < 3 { i += 1; continue }
                if !single || (i > from && !c[i - 1].isWhitespace) { return i }
            }
            i += 1
        }
        return nil
    }

    /// `[label](target "title")` starting at the `[`.
    private static func linkParts(_ c: [Character], from: Int) -> (String, String, Int)? {
        var depth = 0
        var i = from
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "[" { depth += 1 }
            if c[i] == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            i += 1
        }
        guard i + 1 < c.count, c[i] == "]", c[i + 1] == "(" else { return nil }
        let label = String(c[(from + 1)..<i])
        var j = i + 2
        var parens = 1
        var inner = ""
        while j < c.count {
            if c[j] == "(" { parens += 1 }
            if c[j] == ")" {
                parens -= 1
                if parens == 0 { break }
            }
            inner.append(c[j])
            j += 1
        }
        guard j < c.count else { return nil }
        var target = inner.trimmingCharacters(in: .whitespaces)
        if let space = target.firstIndex(of: " "), target[space...].contains("\"") { target = String(target[..<space]) }
        if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
        return (label, target, j + 1)
    }

    private static func merge(_ parts: [MDInline]) -> [MDInline] {
        var out: [MDInline] = []
        for p in parts {
            if var last = out.last, !last.isBreak, !p.isBreak, last.imageSource == nil, p.imageSource == nil,
               last.bold == p.bold, last.italic == p.italic, last.code == p.code, last.strike == p.strike, last.link == p.link {
                last.text += p.text
                out[out.count - 1] = last
            } else {
                out.append(p)
            }
        }
        return out
    }
}
