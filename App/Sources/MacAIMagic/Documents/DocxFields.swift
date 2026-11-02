import Foundation

/// The variable data of a house-style template: {{veld}}, <<veld>> and «veld» anywhere, [Veld] on the cover, content
/// controls by their name, custom document properties with their DOCPROPERTY fields, TITLE and the like, and cover
/// lines such as "Betreft<tab>:<tab>...".
enum DocxFields {
    private static let braces = Rx("\\{\\{\\s*([^{}]{1,60}?)\\s*\\}\\}|<<\\s*([^<>]{1,60}?)\\s*>>|«\\s*([^«»]{1,60}?)\\s*»")
    private static let brackets = Rx("\\[([^\\[\\]]{2,60})\\]")
    private static let labelLine = Rx("^\\s*([^\\t:]{2,40}?)\\s*\\t*:\\s*\\t*(.*)$", .dotMatchesLineSeparators)
    private static let noiseProperties = Rx("^(order|xd_|compliance|templateurl|triggerflow|mediaservice|contenttype|_|msip_|taxcatchall|lcf76f155ced4ddcb4097134ff3c332f)", .caseInsensitive)
    private static let coreFields = ["TITLE", "AUTHOR", "SUBJECT", "KEYWORDS", "LASTSAVEDBY"]
    private static let customPart = "docProps/custom.xml"
    private static let corePart = "docProps/core.xml"
    private static let notKey = Rx("[^a-z0-9]+")
    private static let otherParts = Rx("^word/(header|footer|footnotes|endnotes)\\d*\\.xml$")

    struct Placeholder {
        let key: String
        let label: String
        let source: String
        let current: String
    }

    static func normalized(_ s: String) -> String { notKey.replace(s.lowercased()) { _ in "" } }

    /// The main document, headers, footers, footnotes and endnotes.
    static func textParts(_ pkg: DocxPackage) -> [String] {
        [pkg.mainPart] + pkg.names.filter(otherParts.test)
    }

    // MARK: - fields

    final class FieldRef {
        var instruction: String
        var results: [XNode]

        init(_ instruction: String = "", results: [XNode] = []) {
            self.instruction = instruction
            self.results = results
        }

        var kind: String { instruction.split(whereSeparator: \.isWhitespace).first.map { $0.uppercased() } ?? "" }
        private static let argumentRx = Rx("\\s*\\S+\\s+(?:\"([^\"]+)\"|(\\S+))")
        var argument: String { Self.argumentRx.first(instruction)?.first ?? "" }

        func setResult(_ value: String) {
            guard let first = results.first else { return }
            first.text = value
            first["xml:space"] = "preserve"
            results.dropFirst().forEach { $0.text = "" }
        }
    }

    /// Simple and complex fields of a part in document order, nested ones too.
    static func fields(_ root: XNode) -> [FieldRef] {
        var out: [FieldRef] = []
        var stack: [(field: FieldRef, inResult: Bool)] = []
        root.walk { e in
            guard e.kind == .element else { return }
            switch e.name {
            case "w:fldSimple":
                out.append(FieldRef(e["w:instr"] ?? "", results: e.descendants("w:t")))
            case "w:fldChar":
                switch e["w:fldCharType"] {
                case "begin": stack.append((FieldRef(), false))
                case "separate": if !stack.isEmpty { stack[stack.count - 1].inResult = true }
                case "end": if let f = stack.popLast() { out.append(f.field) }
                default: break
                }
            case "w:instrText":
                stack.last?.field.instruction += e.text
            case "w:t":
                if let top = stack.last, top.inResult, !e.hasAncestor("w:fldSimple") { top.field.results.append(e) }
            default:
                break
            }
        }
        return out
    }

    // MARK: - properties

    private static func customProperties(_ pkg: DocxPackage) -> [(name: String, value: String)] {
        guard pkg.has(customPart), let root = pkg.xml(customPart) else { return [] }
        return root.elements.compactMap { p in
            guard let name = p["name"], !name.hasPrefix("ContentTypeId"), !name.hasPrefix("MediaService"), !name.hasPrefix("_") else { return nil }
            return (name, p.allText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func updateCoreProperties(_ pkg: DocxPackage, title: String? = nil) {
        guard pkg.has(corePart), let root = pkg.xml(corePart) else { return }
        if let title {
            (root.find("dc:title") ?? root.add("dc:title")).text = title
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let modified = root.find("dcterms:modified") ?? root.add("dcterms:modified", ["xsi:type": "dcterms:W3CDTF"])
        modified.text = f.string(from: Date())
    }

    /// Headers often show the file name.
    static func updateFilenameFields(_ pkg: DocxPackage, filename: String) {
        for part in textParts(pkg) {
            guard let root = pkg.xml(part) else { continue }
            for f in fields(root) where f.kind == "FILENAME" {
                f.setResult(f.instruction.lowercased().contains("\\p") ? filename : (filename as NSString).deletingPathExtension)
            }
        }
    }

    // MARK: - finding

    /// `frontUntil`: the first element of the body; before it [Veld] and label lines count too.
    static func placeholders(_ pkg: DocxPackage, frontUntil: XNode?) -> [Placeholder] {
        var found: [Placeholder] = []
        var keys = Set<String>()
        func add(_ label: String, _ source: String, current: String = "") {
            let key = normalized(label)
            guard !key.isEmpty, keys.insert(key).inserted else { return }
            found.append(Placeholder(key: key, label: label.trimmingCharacters(in: .whitespaces), source: source,
                                     current: current.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        var usedProperties = Set<String>()
        for part in textParts(pkg) {
            guard let root = pkg.xml(part) else { continue }
            for f in fields(root) where f.kind == "DOCPROPERTY" && !f.argument.isEmpty { usedProperties.insert(f.argument.lowercased()) }
        }
        for (name, value) in customProperties(pkg) where usedProperties.contains(name.lowercased()) || !noiseProperties.test(name) {
            add(name, "docproperty", current: value)
        }
        for part in textParts(pkg) {
            guard let root = pkg.xml(part) else { continue }
            for sdt in root.descendants("w:sdt") {
                guard let pr = sdt.find("w:sdtPr"), !pr.has("w:docPartObj") else { continue }
                if let label = pr.find("w:alias")?.val ?? pr.find("w:tag")?.val {
                    add(label, "sdt", current: sdt.find("w:sdtContent")?.allText ?? "")
                }
            }
            for f in fields(root) where coreFields.contains(f.kind) {
                add(f.kind.lowercased(), "coreproperty", current: f.results.map(\.text).joined())
            }
            for p in root.descendants("w:p") {
                for m in braces.matches(paragraphText(p)) {
                    if let label = m.first { add(label, "braces") }
                }
            }
        }
        guard let frontUntil else { return found }
        for child in pkg.body.elements {
            if child === frontUntil { break }
            for p in paragraphs(child) {
                if p.hasAncestor("w:sdt"), child.name != "w:sdt" { continue }
                let text = p.descendants("w:t").filter { !$0.hasAncestor("w:sdt", below: p) }.map(\.text).joined()
                for m in brackets.matches(text) {
                    if let label = m.first { add(label, "brackets") }
                }
                let tabbed = textWithTabs(p)
                if tabbed.count < 200, tabbed.contains("\t"), let m = labelLine.first(tabbed), let label = m.groups[0] {
                    add(label, "label", current: (m.groups[1] ?? "").replacingOccurrences(of: "\t", with: " "))
                }
            }
        }
        return found
    }

    private static func paragraphs(_ e: XNode) -> [XNode] { (e.name == "w:p" ? [e] : []) + e.descendants("w:p") }
    private static func paragraphText(_ p: XNode) -> String { p.descendants("w:t").map(\.text).joined() }

    private static func textWithTabs(_ p: XNode) -> String {
        p.descendants("w:t", "w:tab").map { e in
            e.name == "w:t" ? e.text : (e.hasAncestor("w:r", below: p) ? "\t" : "")
        }.joined()
    }

    // MARK: - filling

    /// Fills every kind of placeholder whose name is in `values`; gives the number of places changed.
    static func fill(_ pkg: DocxPackage, values: [String: String], frontUntil: XNode?) -> Int {
        var vals: [String: String] = [:]
        for (k, v) in values where !v.isEmpty { vals[normalized(k)] = v }
        guard !vals.isEmpty else { return 0 }
        var count = 0
        var propertyValues: [String: String] = [:]
        for (name, _) in customProperties(pkg) {
            if let v = vals[normalized(name)] {
                for p in pkg.xml(customPart)?.elements ?? [] where p["name"] == name {
                    p.elements.forEach { $0.text = v }
                }
                propertyValues[name.lowercased()] = v
                count += 1
            }
        }
        var core: [String: String] = [:]
        for k in coreFields {
            if let v = vals[k.lowercased()] { core[k] = v }
        }
        if let t = core["TITLE"] { updateCoreProperties(pkg, title: t) }

        for part in textParts(pkg) {
            guard let root = pkg.xml(part) else { continue }
            for f in fields(root) {
                if f.kind == "DOCPROPERTY", let v = propertyValues[f.argument.lowercased()] { f.setResult(v) }
                else if let v = core[f.kind] { f.setResult(v) }
            }
            for sdt in root.descendants("w:sdt") {
                guard let pr = sdt.find("w:sdtPr") else { continue }
                let alias = normalized(pr.find("w:alias")?.val ?? "")
                let key = alias.isEmpty ? normalized(pr.find("w:tag")?.val ?? "") : alias
                if let v = vals[key] {
                    setControlText(sdt, v)
                    count += 1
                }
            }
            for p in root.descendants("w:p") {
                count += replace(in: p, braces) { m in m.first.flatMap { vals[normalized($0)] } }
            }
        }
        guard let frontUntil else { return count }
        for child in pkg.body.elements {
            if child === frontUntil { break }
            for p in paragraphs(child) {
                count += replace(in: p, brackets) { m in m.first.flatMap { vals[normalized($0)] } }
                count += fillLabelLine(p, vals)
            }
        }
        return count
    }

    /// A replacement over all w:t of a paragraph; the text takes the look of the first run it touches.
    private static func replace(in p: XNode, _ rx: Rx, with: (Rx.Match) -> String?) -> Int {
        let ts = p.descendants("w:t")
        var count = 0
        for m in rx.matches(ts.map(\.text).joined()).reversed() {
            guard let new = with(m) else { continue }
            count += 1
            splice(ts, m.range, new)
        }
        return count
    }

    private static func splice(_ ts: [XNode], _ range: NSRange, _ new: String) {
        let start = range.location, end = range.location + range.length
        var position = 0
        var placed = false
        for t in ts {
            let text = t.text as NSString
            let a = position, b = position + text.length
            position = b
            if !placed, a <= start, start < b || t === ts.last {
                let low = min(start - a, text.length)
                let high = max(min(end, b) - a, low)
                t.text = text.substring(to: low) + new + text.substring(from: high)
                t["xml:space"] = "preserve"
                placed = true
            } else if placed, start <= a, a < end {
                t.text = text.substring(from: min(end, b) - a)
                t["xml:space"] = "preserve"
            }
        }
    }

    /// "Betreft<tab>:<tab>oude waarde": the value changes, the label, tabs and look stay.
    private static func fillLabelLine(_ p: XNode, _ vals: [String: String]) -> Int {
        let tabbed = textWithTabs(p)
        guard tabbed.contains("\t"), let m = labelLine.first(tabbed), let label = m.groups[0], let value = vals[normalized(label)] else { return 0 }
        let ts = p.descendants("w:t")
        let full = ts.map(\.text).joined() as NSString
        let old = (m.groups[1] ?? "").replacingOccurrences(of: "\t", with: "")
        if !old.isEmpty {
            let start = full.length - (old as NSString).length
            splice(ts, NSRange(location: start, length: (old as NSString).length), value)
            return 1
        }
        // no value yet: a new run with the look of the last one
        guard let last = p.descendants("w:r").last, let parent = last.parent else { return 0 }
        let r = last.copy()
        for c in r.children where c.name != "w:rPr" { r.remove(c) }
        r.append(XNode.textElement("w:t", value))
        parent.insertAfter(last, r)
        return 1
    }

    private static func setControlText(_ sdt: XNode, _ value: String) {
        sdt.find("w:sdtPr")?.removeAll("w:showingPlcHdr")
        guard let first = sdt.find("w:sdtContent")?.descendants("w:t").first else { return }
        first.text = value
        first["xml:space"] = "preserve"
        sdt.find("w:sdtContent")?.descendants("w:t").dropFirst().forEach { $0.text = "" }
        if let rpr = first.parent?.find("w:rPr") {
            for s in rpr.findAll("w:rStyle") {
                let v = s.val?.lowercased() ?? ""
                if v.contains("placeholder") || v.contains("tijdelijke") { rpr.remove(s) }
            }
            rpr.removeAll("w:color")
        }
    }

    /// Asks Word to refresh the page numbers of the table of contents when the document opens.
    static func setUpdateFieldsOnOpen(_ pkg: DocxPackage) {
        guard let part = pkg.relatedPart(OOXML.relSettings), let settings = pkg.xml(part) else { return }
        OOXML.put(settings, "w:updateFields", ["w:val": "true"])
    }
}

/// Rebuilds the table of contents, so it is right the moment the file opens. Entries link to `_Toc` bookmarks on the
/// headings; Word fills in the page numbers on opening.
enum DocxTOC {
    private static let tocInstruction = Rx("\\bTOC\\b")
    private static let levels = Rx("\\\\o\\s+\"?(\\d)\\s*-\\s*(\\d)\"?")

    private static func find(_ model: DocModel) -> (container: XNode, first: Int, last: Int, instruction: String)? {
        let body = model.pkg.body
        for c in [body] + body.findAll("w:sdt").compactMap({ $0.find("w:sdtContent") }) {
            let kids = c.elements
            for (i, p) in kids.enumerated() {
                guard p.name == "w:p", tocInstruction.test(p.descendants("w:instrText").map(\.text).joined()) else { continue }
                var depth = 0, started = false
                var instruction = ""
                for j in i..<kids.count {
                    for e in kids[j].descendants("w:fldChar", "w:instrText") {
                        if e.name == "w:instrText" {
                            if depth == 1 { instruction += e.text }
                            continue
                        }
                        if e["w:fldCharType"] == "begin" { depth += 1; started = true }
                        else if e["w:fldCharType"] == "end" {
                            depth -= 1
                            if started && depth == 0 { return (c, i, j, instruction) }
                        }
                    }
                }
                return (c, i, kids.count - 1, instruction)
            }
        }
        return nil
    }

    /// The number of entries; 0 when the document has no table of contents.
    @discardableResult
    static func rebuild(_ model: DocModel) -> Int {
        guard let found = find(model) else { return 0 }
        let maxLevel = levels.first(found.instruction)?.groups[1].flatMap(Int.init) ?? 3
        var nextID = (model.pkg.document.descendants("w:bookmarkStart").compactMap { $0["w:id"].flatMap(Int.init) }.max() ?? 0) + 1

        var entries: [(level: Int, number: String, title: String, bookmark: String, numbered: Bool)] = []
        for node in model.outline() {
            let p = node.block.element
            var name = p.findAll("w:bookmarkStart").compactMap { $0["w:name"] }.first { $0.hasPrefix("_Toc") }
            if name == nil {
                let new = String(format: "_TocMM%06d", nextID)
                let start = XNode("w:bookmarkStart", ["w:id": String(nextID), "w:name": new])
                if let ppr = p.find("w:pPr") { p.insertAfter(ppr, start) } else { p.insert(start, at: 0) }
                p.add("w:bookmarkEnd", ["w:id": String(nextID)])
                nextID += 1
                name = new
            }
            if node.level <= maxLevel {
                entries.append((node.level, node.number, node.title, name!, isNumbered(model, p)))
            }
        }

        let width = HouseStyle.textWidthTwips(model)
        var new: [XNode] = []
        if entries.isEmpty {
            let p = paragraph(model, level: 1, width: width, numbered: false)
            fieldStart(p, found.instruction)
            runText(p, L("Geen koppen gevonden."))
            fieldChar(p, "end")
            new.append(p)
        }
        for (n, e) in entries.enumerated() {
            let p = paragraph(model, level: e.level, width: width, numbered: e.numbered)
            if n == 0 { fieldStart(p, found.instruction) }
            let h = p.add("w:hyperlink", ["w:anchor": e.bookmark, "w:history": "1"])
            if e.numbered, !e.number.isEmpty {
                runText(h, e.number)
                tab(h)
            }
            runText(h, e.title)
            tab(h)
            fieldChar(h, "begin")
            instruction(h, " PAGEREF \(e.bookmark) \\h ")
            fieldChar(h, "separate")
            runText(h, "")
            fieldChar(h, "end")
            if n == entries.count - 1 { fieldChar(p, "end") }
            new.append(p)
        }
        let kids = found.container.elements
        let anchor = kids[found.first]
        for p in new { found.container.insertBefore(anchor, p) }
        for k in found.first...found.last { found.container.remove(kids[k]) }
        DocxFields.setUpdateFieldsOnOpen(model.pkg)
        return entries.count
    }

    private static func isNumbered(_ model: DocModel, _ p: XNode) -> Bool {
        let ppr = p.find("w:pPr")
        if let numPr = ppr?.find("w:numPr") {
            let id = numPr.find("w:numId")?.val
            return id != nil && id != "0"
        }
        return model.styles.isNumbered(ppr?.find("w:pStyle")?.val)
    }

    private static func paragraph(_ model: DocModel, level: Int, width: Int, numbered: Bool) -> XNode {
        var id = model.styles.findTOC(level)
        if id == nil {
            let ppr = XNode("w:pPr")
            OOXML.put(ppr, "w:spacing", ["w:after": "100"])
            OOXML.put(ppr, "w:ind", ["w:left": String(220 * (level - 1))])
            id = model.styles.ensureStyle("TOC\(level)", name: "toc \(level)", basedOn: model.styles.defaultParagraph, ppr: ppr)
        }
        let p = XNode("w:p")
        let ppr = p.add("w:pPr")
        OOXML.put(ppr, "w:pStyle", ["w:val": id ?? ""])
        let tabs = XNode("w:tabs")
        if numbered {
            tabs.add("w:tab", ["w:val": "left", "w:pos": String(220 * (level - 1) + 440 + 220 * max(0, level - 2))])
        }
        tabs.add("w:tab", ["w:val": "right", "w:leader": "dot", "w:pos": String(width)])
        OOXML.put(ppr, tabs)
        return p
    }

    private static func run(_ parent: XNode) -> XNode {
        let r = parent.add("w:r")
        r.add("w:rPr").add("w:noProof")
        return r
    }

    private static func runText(_ parent: XNode, _ text: String) {
        let t = XNode.textElement("w:t", text)
        t["xml:space"] = "preserve"
        run(parent).append(t)
    }

    private static func tab(_ parent: XNode) { run(parent).add("w:tab") }
    private static func fieldChar(_ parent: XNode, _ kind: String) { run(parent).add("w:fldChar", ["w:fldCharType": kind]) }

    private static func instruction(_ parent: XNode, _ text: String) {
        let t = XNode.textElement("w:instrText", text)
        t["xml:space"] = "preserve"
        run(parent).append(t)
    }

    private static func fieldStart(_ p: XNode, _ text: String) {
        fieldChar(p, "begin")
        instruction(p, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " TOC \\o \"1-3\" \\h \\z \\u " : text)
        fieldChar(p, "separate")
    }
}
