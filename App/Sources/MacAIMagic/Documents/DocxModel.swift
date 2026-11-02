import Foundation

/// Which style means what, in any Word language: a built-in style keeps its English name ("heading 1") but gets a
/// translated id ("Kop1" in Dutch Word), and house styles add their own, based on those or with an outline level.
final class StyleSheet {
    struct Style {
        let id: String
        let name: String
        let type: String
        let basedOn: String?
        let outlineLevel: Int?
        let hasNumbering: Bool
        let element: XNode
    }

    private static let headingName = Rx("^(heading|kop|titre|überschrift|uberschrift|encabezado|titolo|rubrik|overskrift|nagłówek)\\s*(\\d)$", .caseInsensitive)
    private static let tocName = Rx("^(toc|inhopg|inhoudsopgave|tdm|verzeichnis|tm)\\s*(\\d)$", .caseInsensitive)
    private static let roles: [String: [String]] = [
        "title": ["title"], "subtitle": ["subtitle"], "list_bullet": ["list bullet"], "list_number": ["list number"],
        "list_paragraph": ["list paragraph"], "caption": ["caption"], "quote": ["quote", "intense quote"],
        "code": ["html preformatted", "plain text", "macro text"], "table_grid": ["table grid"], "hyperlink": ["hyperlink"],
    ]

    private let pkg: DocxPackage
    private let part: String
    private(set) var styles: [String: Style] = [:]
    private var ordered: [Style] = []
    private(set) var defaultParagraph: String?
    private(set) var defaultTable: String?

    init(_ pkg: DocxPackage) {
        self.pkg = pkg
        part = pkg.relatedPart(OOXML.relStyles) ?? "word/styles.xml"
        for s in pkg.xml(part)?.findAll("w:style") ?? [] {
            guard let id = s["w:styleId"] else { continue }
            let type = s["w:type"] ?? "paragraph"
            let ppr = s.find("w:pPr")
            let style = Style(id: id, name: s.find("w:name")?.val ?? id, type: type, basedOn: s.find("w:basedOn")?.val,
                              outlineLevel: ppr?.find("w:outlineLvl")?.val.flatMap(Int.init),
                              hasNumbering: ppr?.has("w:numPr") == true, element: s)
            add(style)
            if s["w:default"] == "1" || s["w:default"] == "true" {
                if type == "paragraph" { defaultParagraph = id } else if type == "table" { defaultTable = id }
            }
        }
    }

    private func add(_ s: Style) {
        styles[s.id] = s
        ordered.append(s)
    }

    func chain(_ id: String?) -> [Style] {
        var out: [Style] = []
        var seen = Set<String>()
        var next = id
        while let i = next, !seen.contains(i), let s = styles[i] {
            seen.insert(i)
            out.append(s)
            next = s.basedOn
        }
        return out
    }

    private static func number(_ rx: Rx, _ s: String) -> Int? {
        rx.first(s.trimmingCharacters(in: .whitespaces))?.groups[1].flatMap(Int.init)
    }

    /// The heading level (from 1) of a paragraph style, or nil.
    func headingLevel(_ id: String?) -> Int? {
        for s in chain(id) {
            if let n = Self.number(Self.headingName, s.name) ?? Self.number(Self.headingName, s.id) { return n }
            if let o = s.outlineLevel, o < 9 { return o + 1 }
            if ["title", "subtitle"].contains(s.name.lowercased()) { return nil }
        }
        return nil
    }

    func tocLevel(_ id: String?) -> Int? {
        guard let id, let s = styles[id] else { return nil }
        return Self.number(Self.tocName, s.name) ?? Self.number(Self.tocName, s.id)
    }

    func hasRole(_ id: String?, _ role: String) -> Bool {
        let names = Self.roles[role] ?? []
        return chain(id).contains { names.contains($0.name.lowercased()) }
    }

    func isNumbered(_ id: String?) -> Bool { chain(id).contains(where: \.hasNumbering) }

    func findRole(_ role: String) -> String? {
        for name in Self.roles[role] ?? [] {
            if let s = ordered.first(where: { $0.name.lowercased() == name }) { return s.id }
        }
        return nil
    }

    func findHeading(_ level: Int) -> String? {
        var best: String?
        for s in ordered where s.type == "paragraph" {
            if Self.number(Self.headingName, s.name) == level { return s.id }
            if best == nil && headingLevel(s.id) == level { best = s.id }
        }
        return best
    }

    func findTOC(_ level: Int) -> String? { ordered.first { Self.number(Self.tocName, $0.name) == level }?.id }

    /// A minimal style when the template lacks one (for example for captions).
    func ensureStyle(_ id: String, name: String, basedOn: String? = nil, ppr: XNode? = nil, rpr: XNode? = nil) -> String {
        if styles[id] != nil { return id }
        guard let root = pkg.xml(part) else { return id }
        let s = root.add("w:style", ["w:type": "paragraph", "w:styleId": id])
        s.add("w:name", ["w:val": name])
        if let basedOn { s.add("w:basedOn", ["w:val": basedOn]) }
        s.add("w:qFormat")
        if let ppr { s.append(ppr) }
        if let rpr { s.append(rpr) }
        add(Style(id: id, name: name, type: "paragraph", basedOn: basedOn, outlineLevel: nil, hasNumbering: false, element: s))
        return id
    }
}

/// Just enough of numbering.xml: is a list a bullet list or a numbered one?
final class NumberingReader {
    private var formats: [String: String] = [:]

    init(_ pkg: DocxPackage) {
        guard let part = pkg.relatedPart(OOXML.relNumbering), let root = pkg.xml(part) else { return }
        var abstract: [String: [Int: String]] = [:]
        for a in root.findAll("w:abstractNum") {
            var levels: [Int: String] = [:]
            for l in a.findAll("w:lvl") { levels[Int(l["w:ilvl"] ?? "0") ?? 0] = l.find("w:numFmt")?.val ?? "decimal" }
            abstract[a["w:abstractNumId"] ?? ""] = levels
        }
        for n in root.findAll("w:num") {
            for (level, format) in abstract[n.find("w:abstractNumId")?.val ?? ""] ?? [:] {
                formats["\(n["w:numId"] ?? "")/\(level)"] = format
            }
        }
    }

    func numbering(of p: XNode, styles: StyleSheet) -> (level: Int, ordered: Bool)? {
        let ppr = p.find("w:pPr")
        var numPr = ppr?.find("w:numPr")
        if numPr == nil {
            numPr = styles.chain(ppr?.find("w:pStyle")?.val).first(where: \.hasNumbering)?.element.find("w:pPr")?.find("w:numPr")
        }
        guard let numPr, let id = numPr.find("w:numId")?.val, id != "0" else { return nil }
        let level = Int(numPr.find("w:ilvl")?.val ?? "0") ?? 0
        let format = formats["\(id)/\(level)"] ?? "bullet"
        return (level, format != "bullet" && format != "none")
    }
}

struct Span {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var link: String?

    func sameFormat(_ o: Span) -> Bool { bold == o.bold && italic == o.italic && code == o.code && link == o.link }
}

/// One thing in the body, with a pointer to its real XML: later steps work on the document itself, not on a copy.
final class Block {
    enum Kind { case heading, paragraph, list, table, toc, image, pageBreak, section, other }

    var kind: Kind
    let element: XNode
    var styleID: String?
    var level = 0
    var ordered = false
    var spans: [Span] = []
    var rows: [[String]] = []
    var images: [String] = []
    var hasSectionBreak = false

    init(_ kind: Kind, _ element: XNode, styleID: String? = nil) {
        self.kind = kind
        self.element = element
        self.styleID = styleID
    }

    var text: String {
        kind == .table ? rows.map { $0.joined(separator: " | ") }.joined(separator: "\n") : spans.map(\.text).joined()
    }

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct OutlineNode {
    let block: Block
    let title: String
    let level: Int
    let number: String
    /// The heading's place in `blocks`, and where the section ends (with its subsections).
    let start: Int
    let end: Int
}

/// A .docx read into blocks.
final class DocModel {
    let pkg: DocxPackage
    let styles: StyleSheet
    let numbering: NumberingReader
    private(set) var blocks: [Block] = []

    init(_ pkg: DocxPackage) {
        self.pkg = pkg
        styles = StyleSheet(pkg)
        numbering = NumberingReader(pkg)
        for child in pkg.body.elements {
            switch child.name {
            case "w:p": blocks.append(paragraph(child))
            case "w:tbl": blocks.append(table(child))
            case "w:sdt": blocks.append(contentControl(child))
            case "w:sectPr": blocks.append(Block(.section, child))
            default: blocks.append(Block(.other, child))
            }
        }
    }

    private static let tocInstruction = Rx("\\bTOC\\b")

    private func paragraph(_ p: XNode) -> Block {
        let ppr = p.find("w:pPr")
        let id = ppr?.find("w:pStyle")?.val ?? styles.defaultParagraph
        let b = Block(.paragraph, p, styleID: id)
        (b.spans, b.images) = spans(p)
        b.hasSectionBreak = ppr?.has("w:sectPr") == true
        if p.descendants("w:instrText").contains(where: { Self.tocInstruction.test($0.text) }) || styles.tocLevel(id) != nil {
            b.kind = .toc
            return b
        }
        var level = styles.headingLevel(id)
        if level == nil, let o = ppr?.find("w:outlineLvl")?.val.flatMap(Int.init), o < 9 { level = o + 1 }
        if let level, !b.isBlank {
            b.kind = .heading
            b.level = level
            return b
        }
        if let n = numbering.numbering(of: p, styles: styles), !b.isBlank {
            b.kind = .list
            b.level = n.level
            b.ordered = n.ordered
            return b
        }
        if b.isBlank {
            if !b.images.isEmpty { b.kind = .image }
            else if p.descendants("w:br").contains(where: { $0["w:type"] == "page" }) { b.kind = .pageBreak }
        }
        return b
    }

    private func spans(_ p: XNode) -> ([Span], [String]) {
        var out: [Span] = []
        var images: [String] = []
        func add(_ s: Span) {
            if let last = out.last, last.sameFormat(s) { out[out.count - 1].text += s.text } else { out.append(s) }
        }
        func walk(_ node: XNode, link: String?) {
            for c in node.elements {
                switch c.name {
                case "w:r":
                    let rpr = c.find("w:rPr")
                    let code = rpr?.find("w:rStyle")?.val?.lowercased().contains("code") == true
                    let template = Span(text: "", bold: Self.isOn(rpr, "w:b"), italic: Self.isOn(rpr, "w:i"), code: code, link: link)
                    func text(_ s: String) { var x = template; x.text = s; add(x) }
                    for t in c.elements {
                        switch t.name {
                        case "w:t": text(t.text)
                        case "w:tab": text("\t")
                        case "w:br", "w:cr": if t["w:type"] != "page" { text("\n") }
                        case "w:noBreakHyphen": text("-")
                        case "w:drawing", "w:pict":
                            t.walk { e in
                                let id = e.name == "a:blip" ? e["r:embed"] : e.name == "v:imagedata" ? e["r:id"] : nil
                                if let id, let part = pkg.partForRelationship(pkg.mainPart, id) { images.append(part) }
                            }
                        default: break
                        }
                    }
                case "w:hyperlink":
                    var target = link
                    if let id = c["r:id"] { target = pkg.relationship(pkg.mainPart, id)?.target } else if let a = c["w:anchor"] { target = "#" + a }
                    walk(c, link: target)
                case "w:ins", "w:smartTag", "w:customXml", "w:fldSimple", "w:sdt", "w:sdtContent":
                    walk(c, link: link)
                default:
                    break   // w:del, bookmarks and the like carry no visible text
                }
            }
        }
        walk(p, link: nil)
        return (out, images)
    }

    private static func isOn(_ rpr: XNode?, _ name: String) -> Bool {
        guard let e = rpr?.find(name) else { return false }
        return !["0", "false", "off"].contains(e.val ?? "1")
    }

    private func table(_ tbl: XNode) -> Block {
        let b = Block(.table, tbl, styleID: tbl.find("w:tblPr")?.find("w:tblStyle")?.val)
        b.rows = tbl.findAll("w:tr").map { tr in
            tr.findAll("w:tc").map { tc in
                tc.descendants("w:p").map { spans($0).0.map(\.text).joined() }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return b
    }

    private func contentControl(_ sdt: XNode) -> Block {
        let gallery = sdt.find("w:sdtPr")?.find("w:docPartObj")?.find("w:docPartGallery")?.val ?? ""
        if gallery.contains("Table of Contents") || sdt.descendants("w:instrText").contains(where: { $0.text.contains("TOC") }) {
            return Block(.toc, sdt)
        }
        let b = Block(.other, sdt)
        for p in sdt.find("w:sdtContent")?.findAll("w:p") ?? [] {
            if !b.spans.isEmpty { b.spans.append(Span(text: "\n")) }
            b.spans += spans(p).0
        }
        return b
    }

    /// Word's numbering of the headings, and where each section ends.
    func outline() -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        var counters = [Int](repeating: 0, count: 10)
        let heads = blocks.enumerated().filter { $0.element.kind == .heading }
        for (n, head) in heads.enumerated() {
            let b = head.element
            counters[b.level - 1] += 1
            for k in b.level..<10 { counters[k] = 0 }
            let number = counters[..<b.level].filter { $0 > 0 }.map(String.init).joined(separator: ".")
            let end = heads[(n + 1)...].first { $0.element.level <= b.level }?.offset ?? blocks.count
            nodes.append(OutlineNode(block: b, title: b.text.trimmingCharacters(in: .whitespacesAndNewlines), level: b.level,
                                     number: number.isEmpty ? String(counters[0]) : number, start: head.offset, end: end))
        }
        return nodes
    }

    /// Where the body starts: the first real heading after the cover and the table of contents.
    var bodyStart: Int {
        if let i = blocks.firstIndex(where: { $0.kind == .heading }) { return i }
        return (blocks.lastIndex { $0.kind == .toc || $0.hasSectionBreak } ?? -1) + 1
    }
}

/// The Markdown form of what was read.
enum DocxMarkdown {
    static func block(_ b: Block) -> String? {
        switch b.kind {
        case .heading:
            return String(repeating: "#", count: min(b.level, 6)) + " " + spans(b.spans).trimmingCharacters(in: .whitespacesAndNewlines)
        case .paragraph:
            let t = spans(b.spans).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case .list:
            return String(repeating: "  ", count: b.level) + (b.ordered ? "1. " : "- ") + spans(b.spans).trimmingCharacters(in: .whitespacesAndNewlines)
        case .table:
            return table(b.rows)
        case .image:
            return b.images.map { "![](\($0))" }.joined(separator: "\n")
        case .other:
            return b.isBlank ? nil : b.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .toc, .pageBreak, .section:
            return nil
        }
    }

    static func spans(_ spans: [Span]) -> String {
        var out = ""
        for s in spans where !s.text.isEmpty {
            let core = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if core.isEmpty { out += s.text; continue }
            let lead = s.text.prefix { $0.isWhitespace }
            let trail = String(s.text.reversed().prefix { $0.isWhitespace }.reversed())
            var t = core
            if s.code { t = "`\(core)`" }
            else if s.bold && s.italic { t = "***\(core)***" }
            else if s.bold { t = "**\(core)**" }
            else if s.italic { t = "*\(core)*" }
            if let link = s.link, !link.hasPrefix("#") { t = "[\(t)](\(link))" }
            out += lead + t + trail
        }
        return out.replacingOccurrences(of: "\t", with: " ")
    }

    static func table(_ rows: [[String]]) -> String {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        let cells = rows.map { row in
            row.map { $0.replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|") }
                + [String](repeating: "", count: width - row.count)
        }
        let lines = ["| " + cells[0].joined(separator: " | ") + " |", "|" + String(repeating: "---|", count: width)]
            + cells.dropFirst().map { "| " + $0.joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n")
    }
}

/// A paragraph's look, cloned from an example.
struct ParaFormat {
    var styleID: String?
    var ppr: XNode?
    var rpr: XNode?

    init(_ styleID: String?, ppr: XNode? = nil, rpr: XNode? = nil) {
        self.styleID = styleID
        self.ppr = ppr
        self.rpr = rpr
    }

    func newPPr() -> XNode {
        let p = ppr?.copy() ?? XNode("w:pPr")
        p.removeAll("w:sectPr")
        p.removeAll("w:pPrChange")
        if let styleID { OOXML.put(p, "w:pStyle", ["w:val": styleID]) }
        return p
    }

    func newRPr() -> XNode? { rpr?.copy() }
}

/// The house style learned from the document's own examples. Templates are rarely clean: some use styles, others
/// formatting by hand. So each role (heading, body, list, table) takes its look from what the template really uses,
/// and new text looks as if the template's author wrote it.
final class HouseStyle {
    let model: DocModel
    private(set) var headings: [Int: ParaFormat] = [:]
    private(set) var bodyFormat = ParaFormat(nil)
    private(set) var bullet: ParaFormat?
    private(set) var number: ParaFormat?
    private(set) var quote: ParaFormat?
    private(set) var caption: ParaFormat?
    private(set) var code: ParaFormat?
    private(set) var tableExample: XNode?
    private(set) var headingsNumbered = false

    private static let guidance = Rx("^\\s*(\\[.*\\]|<<.*>>|\\{\\{.*\\}\\}|<.*>)\\s*$", .dotMatchesLineSeparators)
    private static let placeholderColors: Set<String> = ["808080", "7F7F7F", "A6A6A6", "BFBFBF", "FF0000", "C00000", "0070C0", "999999", "595959"]
    private static let rprStrip = ["w:b", "w:bCs", "w:i", "w:iCs", "w:highlight", "w:vanish", "w:strike", "w:rStyle", "w:lang", "w:noProof", "w:webHidden", "w:u"]

    /// Instruction text of a template such as "[Beschrijf hier ...]", which must not end up in the result.
    static func isGuidance(_ b: Block) -> Bool {
        let t = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if guidance.test(t) { return true }
        let runs = b.element.descendants("w:r").filter { !$0.allText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !runs.isEmpty && runs.allSatisfy(runIsPlaceholder)
    }

    private static func runIsPlaceholder(_ r: XNode) -> Bool {
        guard let rpr = r.find("w:rPr") else { return false }
        let style = rpr.find("w:rStyle")?.val?.lowercased() ?? ""
        if style.contains("placeholder") || style.contains("tijdelijke") { return true }
        if rpr.has("w:highlight") { return true }
        return rpr.has("w:i") && placeholderColors.contains((rpr.find("w:color")?.val ?? "").uppercased())
    }

    init(_ model: DocModel) {
        self.model = model
        let st = model.styles
        let blocks = model.blocks
        let region = blocks[(blocks.firstIndex { $0.kind == .heading } ?? 0)...]

        for level in 1...9 {
            let found = region.filter { $0.kind == .heading && $0.level == level }
            if !found.isEmpty { headings[level] = Self.format(found) }
            else if let id = st.findHeading(level) { headings[level] = ParaFormat(id) }
        }
        var paragraphs = region.filter { $0.kind == .paragraph && !$0.isBlank && !Self.isGuidance($0) }
        if paragraphs.isEmpty {
            paragraphs = blocks.filter {
                $0.kind == .paragraph && !$0.isBlank && !Self.isGuidance($0) && st.headingLevel($0.styleID) == nil
                    && !st.hasRole($0.styleID, "title") && !st.hasRole($0.styleID, "subtitle")
            }
        }
        bodyFormat = paragraphs.isEmpty ? ParaFormat(st.defaultParagraph) : Self.format(paragraphs)
        // the body's example must not bring list numbering or keep-with-next along
        for t in ["w:numPr", "w:keepNext", "w:pageBreakBefore", "w:outlineLvl"] { bodyFormat.ppr?.removeAll(t) }

        let bullets = blocks.filter { $0.kind == .list && !$0.ordered && !Self.isGuidance($0) }
        let numbers = blocks.filter { $0.kind == .list && $0.ordered && !Self.isGuidance($0) }
        bullet = bullets.isEmpty ? role("list_bullet") : Self.format(bullets)
        number = numbers.isEmpty ? role("list_number") : Self.format(numbers)
        quote = role("quote")
        caption = role("caption")
        code = role("code")
        tableExample = (region.first { $0.kind == .table } ?? blocks.first { $0.kind == .table })?.element
        headingsNumbered = headings.values.contains { $0.ppr?.has("w:numPr") == true || st.isNumbered($0.styleID) }
    }

    private func role(_ name: String) -> ParaFormat? { model.styles.findRole(name).map { ParaFormat($0) } }

    func heading(_ level: Int) -> ParaFormat {
        if let f = headings[level] { return f }
        // deeper than the template defines: the look of the deepest level it has
        if let deepest = headings.keys.filter({ $0 < level }).max(), let f = headings[deepest] { return f }
        return ParaFormat(model.styles.findHeading(level))
    }

    private static func format(_ blocks: some Collection<Block>) -> ParaFormat {
        var counts: [String: Int] = [:]
        for b in blocks { counts[b.styleID ?? "", default: 0] += 1 }
        // the most used style, the first in the document on a tie
        let best = blocks.map { $0.styleID ?? "" }.max { counts[$0]! < counts[$1]! } ?? ""
        let same = blocks.filter { ($0.styleID ?? "") == best }
        return ParaFormat(best.isEmpty ? nil : best, ppr: same.first?.element.find("w:pPr")?.copy(), rpr: dominantRPr(same))
    }

    /// Formatting by hand shared by most of the text (say Arial 10 applied to everything).
    private static func dominantRPr(_ blocks: [Block]) -> XNode? {
        var weights: [String: Int] = [:]
        var samples: [String: XNode] = [:]
        var total = 0
        for b in blocks {
            for r in b.element.descendants("w:r") {
                let n = r.findAll("w:t").map(\.text.utf16.count).reduce(0, +)
                guard n > 0 else { continue }
                total += n
                var key = ""
                if let rpr = r.find("w:rPr")?.copy() {
                    rprStrip.forEach(rpr.removeAll)
                    if !rpr.elements.isEmpty {
                        key = rpr.signature
                        if samples[key] == nil { samples[key] = rpr }
                    }
                }
                weights[key, default: 0] += n
            }
        }
        guard total > 0, let best = weights.max(by: { $0.value < $1.value }), !best.key.isEmpty,
              Double(best.value) / Double(total) >= 0.6 else { return nil }
        return samples[best.key]
    }

    static func textWidthTwips(_ model: DocModel) -> Int {
        if let sect = model.pkg.body.find("w:sectPr"),
           let w = sect.find("w:pgSz")?["w:w"].flatMap(Int.init), let mar = sect.find("w:pgMar"),
           let left = mar["w:left"].flatMap(Int.init), let right = mar["w:right"].flatMap(Int.init) {
            return w - left - right
        }
        return 9026   // A4 with 2.54 cm margins
    }
}
