import Foundation

/// A draft in Markdown, with the template's variable fields at the top between --- lines.
struct DocumentDraft: Equatable {
    var fields: [(key: String, value: String)] = []
    var body = ""

    static func == (a: DocumentDraft, b: DocumentDraft) -> Bool {
        a.body == b.body && a.fields.map(\.key) == b.fields.map(\.key) && a.fields.map(\.value) == b.fields.map(\.value)
    }

    init(fields: [(key: String, value: String)] = [], body: String = "") {
        self.fields = fields
        self.body = body
    }

    init(markdown: String) {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            body = text
            return
        }
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if !key.isEmpty { fields.append((key, value)) }
        }
        body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    var markdown: String {
        guard !fields.isEmpty else { return body }
        let head = fields.map { f in
            let plain = f.value.isEmpty || !(f.value.contains(":") || f.value.contains("#") || f.value.hasPrefix("\""))
            return "\(f.key): " + (plain ? f.value : "\"\(f.value.replacingOccurrences(of: "\"", with: "'"))\"")
        }
        return "---\n" + head.joined(separator: "\n") + "\n---\n\n" + body
    }

    private static let fieldMark = Rx("^(\\[.*\\]|\\{\\{.*\\}\\}|<<.*>>|«.*»)$")

    /// No value yet: nothing, or the template's own marking such as "[Klantnaam]".
    static func isEmptyField(_ value: String) -> Bool {
        let t = value.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || fieldMark.test(t)
    }

    /// The title for the cover and the properties: the field with that name, else the first heading.
    var title: String? {
        let names = Set(["titel", "title", "titre", "onderwerp", "betreft", "subject"])
        if let f = fields.first(where: { names.contains(DocxFields.normalized($0.key)) && !$0.value.isEmpty }) { return f.value }
        return MarkdownBlocks.parse(body).first { $0.kind == .heading }?.plain
    }
}

/// From a template to Markdown and back: the cover, table of contents, sections, headers and footers stay the
/// template's own, and only the body is written anew.
enum DocxCompose {
    struct Report {
        var url: URL?
        var blocks = 0
        var fieldsFilled = 0
        var tocEntries = 0
        /// What the reader of the document would notice: sections that are gone, fields without a value.
        var warnings: [String] = []
        /// What is wrong with the file itself; empty when it is sound.
        var problems: [String] = []
    }

    /// `template`: a template's bytes, or nil for the built-in plain house style.
    static func build(template: Data?, markdown: String, to out: URL, images: ImageResolver? = nil) throws -> Report {
        let pkg = try template.map { try DocxPackage(data: $0) } ?? plainTemplate()
        let draft = DocumentDraft(markdown: markdown)
        let model = DocModel(pkg)
        var report = Report()
        // the images of the template first: its draft refers to them by their name in the package
        let own = templateImages(pkg)
        let builder = DocxBuilder(model, images: { own($0) ?? images?($0) })   // learns the house style before anything goes
        var removed = 0
        for b in model.blocks[model.bodyStart...] where b.kind != .section {
            if b.hasSectionBreak { removed += 1 }
            b.element.removeFromParent()
        }
        if removed > 0 { report.warnings.append(L("\(removed) sectie-einde(n) in de sjabloonbody zijn vervallen; de laatste sectie-opmaak is behouden.")) }

        let elements = builder.build(markdown: draft.body)
        let body = pkg.body
        if let last = body.find("w:sectPr") {
            elements.forEach { body.insertBefore(last, $0) }
        } else {
            elements.forEach { body.append($0) }
        }
        report.blocks = elements.count

        var values = Dictionary(draft.fields.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        // the title goes on the cover under either name, unless the draft says otherwise
        if let title = draft.title {
            let given = Set(values.keys.map(DocxFields.normalized))
            for name in ["titel", "title"] where !given.contains(name) { values[name] = title }
        }
        report.fieldsFilled = DocxFields.fill(pkg, values: values, frontUntil: elements.first)
        let empty = draft.fields.filter { DocumentDraft.isEmptyField($0.value) }.map(\.key)
        if !empty.isEmpty { report.warnings.append(L("Nog niet ingevuld: \(empty.joined(separator: ", ")).")) }

        DocxFields.updateFilenameFields(pkg, filename: out.lastPathComponent)
        report.tocEntries = DocxTOC.rebuild(DocModel(pkg))
        DocxFields.updateCoreProperties(pkg, title: draft.title)

        let data = pkg.toData()
        report.problems = DocxValidator.validate(data)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: out, options: .atomic)
        report.url = out
        return report
    }

    /// A template as a draft: its fields on top, its body as Markdown, and its instructions as comments for the model.
    /// They stay out of the document.
    static func draft(template: Data) throws -> String {
        let pkg = try DocxPackage(data: template)
        let model = DocModel(pkg)
        let start = model.bodyStart
        let front = start < model.blocks.count ? model.blocks[start].element : nil
        var parts: [String] = []
        for b in model.blocks[start...] {
            if HouseStyle.isGuidance(b) {
                let t = b.text.trimmingCharacters(in: CharacterSet(charactersIn: "[]<>{} \n\t"))
                if !t.isEmpty { parts.append("<!-- " + L("instructie") + ": " + t.replacingOccurrences(of: "--", with: "–") + " -->") }
            } else if let md = DocxMarkdown.block(b) {
                parts.append(md)
            }
        }
        let fields = DocxFields.placeholders(pkg, frontUntil: front).filter { $0.source != "coreproperty" }.map { (key: $0.label, value: $0.current) }
        return DocumentDraft(fields: fields, body: parts.joined(separator: "\n\n") + "\n").markdown
    }

    /// The images inside the template, which its draft refers to by their name in the package.
    private static func templateImages(_ pkg: DocxPackage) -> ImageResolver {
        { name in name.hasPrefix("word/media/") ? pkg.data(name).map { ($0, (name as NSString).pathExtension) } : nil }
    }

    /// Without a template of the project: a plain, tidy document with a title and a table of contents.
    static func plainTemplate() throws -> DocxPackage {
        let w = "xmlns:w=\"\(OOXML.wordNamespace)\""
        let toc = "<w:p><w:pPr><w:pStyle w:val=\"TOC1\"/></w:pPr><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + "<w:r><w:instrText xml:space=\"preserve\"> TOC \\o \"1-3\" \\h \\z \\u </w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
        func heading(_ n: Int, _ size: Int) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:spacing w:before=\"\(n == 1 ? 360 : 240)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr>"
                + "<w:rPr><w:b/><w:color w:val=\"1F3864\"/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        func simple(_ id: String, _ name: String, _ inner: String) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>\(inner)</w:style>"
        }
        let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles \(w)>"
            + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"264\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + heading(1, 32) + heading(2, 26) + heading(3, 23)
            + simple("Title", "Title", "<w:pPr><w:spacing w:after=\"480\"/></w:pPr><w:rPr><w:b/><w:color w:val=\"1F3864\"/><w:sz w:val=\"52\"/></w:rPr>")
            + simple("Quote", "Quote", "<w:pPr><w:ind w:left=\"567\"/></w:pPr><w:rPr><w:i/></w:rPr>")
            + simple("Caption", "caption", "<w:rPr><w:i/><w:sz w:val=\"18\"/></w:rPr>")
            + simple("TOC1", "toc 1", "<w:pPr><w:spacing w:after=\"80\"/></w:pPr>")
            + simple("TOC2", "toc 2", "<w:pPr><w:spacing w:after=\"80\"/><w:ind w:left=\"220\"/></w:pPr>")
            + simple("TOC3", "toc 3", "<w:pPr><w:spacing w:after=\"80\"/><w:ind w:left=\"440\"/></w:pPr>")
            + "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableGrid\"><w:name w:val=\"Table Grid\"/><w:tblPr><w:tblBorders>"
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A6A6A6\"/>" }.joined()
            + "</w:tblBorders></w:tblPr></w:style></w:styles>"
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(w) xmlns:r=\"\(OOXML.drawing["r"] ?? "")\"><w:body>"
            + "<w:p><w:pPr><w:pStyle w:val=\"Title\"/></w:pPr><w:r><w:t>{{titel}}</w:t></w:r></w:p>" + toc
            + "<w:p><w:pPr><w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t>-</w:t></w:r></w:p>"
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>"
            + "</w:body></w:document>"
        let main = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        return try DocxPackage(parts: [
            ("[Content_Types].xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/word/document.xml\" ContentType=\"\(main).document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"\(main).styles+xml\"/>"
                + "<Override PartName=\"/word/settings.xml\" ContentType=\"\(main).settings+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"),
            ("_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(OOXML.relOfficeDocument)\" Target=\"word/document.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>"),
            ("word/_rels/document.xml.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"\(OOXML.relStyles)\" Target=\"styles.xml\"/><Relationship Id=\"rId2\" Type=\"\(OOXML.relSettings)\" Target=\"settings.xml\"/></Relationships>"),
            ("word/document.xml", document),
            ("word/styles.xml", styles),
            ("word/settings.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:settings \(w)><w:defaultTabStop w:val=\"708\"/></w:settings>"),
            ("docProps/core.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
                + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title></dc:title></cp:coreProperties>"),
        ])
    }
}

/// Checks a document before the user gets it: what would make Word refuse or repair the file.
enum DocxValidator {
    static func validate(_ data: Data) -> [String] {
        guard let entries = try? Zip.read(data) else { return [L("Het bestand is geen geldig zip-pakket.")] }
        var problems: [String] = []
        var xml: [String: XNode] = [:]
        let names = Set(entries.map(\.name))
        for (name, content) in entries where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            if let root = try? XNode.parse(content) { xml[name] = root } else { problems.append(L("\(name): XML ongeldig")) }
        }
        guard let types = xml["[Content_Types].xml"] else { return problems + [L("[Content_Types].xml ontbreekt")] }
        let defaults = Set(types.findAll("Default").compactMap { $0["Extension"]?.lowercased() })
        let overrides = Set(types.findAll("Override").compactMap { $0["PartName"] })
        for n in names where n != "[Content_Types].xml" && !overrides.contains("/" + n) && !defaults.contains(n.components(separatedBy: ".").last?.lowercased() ?? "") {
            problems.append(L("Geen content type voor \(n)"))
        }
        for (n, root) in xml where n.hasSuffix(".rels") {
            let source = ((n as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            for r in root.elements where r["TargetMode"] != "External" {
                let target = r["Target"] ?? ""
                let path = target.hasPrefix("/") ? String(target.dropFirst()) : OOXML.normalized((source as NSString).appendingPathComponent(target))
                if !names.contains(path) { problems.append(L("\(n): relatie \(r["Id"] ?? "") wijst naar ontbrekend \(path)")) }
            }
        }
        if let doc = xml["word/document.xml"] { problems += check(doc) }
        return problems
    }

    private static func check(_ doc: XNode) -> [String] {
        var out: [String] = []
        func duplicates(_ values: [String]) -> [String] {
            var seen = Set<String>(), dup = Set<String>()
            for v in values where !seen.insert(v).inserted { dup.insert(v) }
            return dup.sorted()
        }
        let bookmarks = doc.descendants("w:bookmarkStart")
        for (what, list) in [(L("bladwijzer-ID's"), bookmarks.compactMap { $0["w:id"] }),
                             (L("bladwijzernamen"), bookmarks.compactMap { $0["w:name"] }),
                             (L("tekening-ID's"), doc.descendants("wp:docPr").compactMap { $0["id"] })] {
            let d = duplicates(list)
            if !d.isEmpty { out.append(L("Dubbele \(what): \(d.prefix(5).joined(separator: ", "))")) }
        }
        for kind in ["w:pPr", "w:rPr", "w:tcPr", "w:tblPr"] {
            guard let index = OOXML.orderIndex[kind] else { continue }
            for e in doc.descendants(kind) {
                if kind == "w:rPr", let parent = e.parent?.name, parent != "w:r", parent != "w:pPr" { continue }
                let seq = e.elements.compactMap { index[$0.name] }
                if seq != seq.sorted() {
                    out.append(L("Verkeerde volgorde in \(kind): \(e.elements.map(\.name).joined(separator: ", "))"))
                    break
                }
            }
        }
        let chars = doc.descendants("w:fldChar")
        let begins = chars.filter { $0["w:fldCharType"] == "begin" }.count
        let ends = chars.filter { $0["w:fldCharType"] == "end" }.count
        if begins != ends { out.append(L("Velden niet in balans: \(begins) begin / \(ends) end")) }
        if let last = doc.find("w:body")?.elements.last, last.name != "w:sectPr" { out.append(L("Laatste body-element is geen sectPr")) }
        // a prefix without a declaration makes the whole file unreadable
        var declared = Set(doc.attributes.keys.filter { $0.hasPrefix("xmlns:") }.map { String($0.dropFirst(6)) })
        declared.insert("xml")
        var missing = Set<String>()
        func walk(_ e: XNode, _ scope: Set<String>) {
            var inner = scope
            for k in e.attributes.keys where k.hasPrefix("xmlns:") { inner.insert(String(k.dropFirst(6))) }
            for name in [e.name] + Array(e.attributes.keys) where !name.hasPrefix("xmlns") {
                if let colon = name.firstIndex(of: ":"), !inner.contains(String(name[..<colon])) { missing.insert(String(name[..<colon])) }
            }
            for c in e.elements { walk(c, inner) }
        }
        walk(doc, declared)
        if !missing.isEmpty { out.append(L("Niet gedeclareerde XML-voorvoegsels: \(missing.sorted().joined(separator: ", "))")) }
        return out
    }
}
