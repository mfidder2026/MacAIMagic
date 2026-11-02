import Foundation
import ImageIO

/// The bytes and extension of an image a document refers to, or nil.
typealias ImageResolver = (String) -> (Data, String)?

/// Turns Markdown into OOXML in the house style of the document it goes into.
final class DocxBuilder {
    private static let leadingNumber = Rx("^\\s*(?:(?:hoofdstuk|chapter|bijlage)\\s+)?\\d+(?:\\.\\d+)*\\.?\\s+", .caseInsensitive)
    private static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp",
                                     "svg": "image/svg+xml", "emf": "image/x-emf", "wmf": "image/x-wmf", "tif": "image/tiff", "tiff": "image/tiff"]
    private static let emuPerTwip = 635

    let model: DocModel
    let style: HouseStyle
    private let pkg: DocxPackage
    private let images: ImageResolver?
    private let numbering: NumberingWriter
    private var bookmarkID: Int
    private var drawingID: Int
    private var listNumbers: [Int: String] = [:]
    private var figure = 0
    let widthTwips: Int

    init(_ model: DocModel, images: ImageResolver? = nil) {
        self.model = model
        self.images = images
        pkg = model.pkg
        style = HouseStyle(model)
        numbering = NumberingWriter(model.pkg)
        bookmarkID = Self.maxAttribute(pkg.document, "w:bookmarkStart", "w:id") + 1
        drawingID = Self.maxAttribute(pkg.document, "wp:docPr", "id") + 1
        widthTwips = HouseStyle.textWidthTwips(model)
    }

    private static func maxAttribute(_ root: XNode, _ element: String, _ attribute: String) -> Int {
        root.descendants(element).compactMap { $0[attribute].flatMap(Int.init) }.max() ?? 0
    }

    func build(markdown: String) -> [XNode] {
        MarkdownBlocks.parse(markdown).flatMap(block)
    }

    private func block(_ s: MDBlock) -> [XNode] {
        switch s.kind {
        case .heading: return [heading(s)]
        case .paragraph: return [paragraph(style.bodyFormat, s.inlines)]
        case .list: return [listItem(s)]
        case .quote: return [quote(s)]
        case .code: return code(s)
        case .caption: return [paragraph(captionFormat, s.inlines)]
        case .pageBreak:
            let p = XNode("w:p")
            p.add("w:r").add("w:br", ["w:type": "page"])
            return [p]
        case .image: return image(s)
        case .table: return table(s)
        }
    }

    private func heading(_ s: MDBlock) -> XNode {
        var parts = s.inlines
        // the template numbers its headings itself: "1.1 Aanleiding" would become "1.1 1.1 Aanleiding"
        if style.headingsNumbered, !parts.isEmpty {
            parts[0].text = Self.leadingNumber.replace(parts[0].text) { _ in "" }
        }
        let p = paragraph(style.heading(s.level), parts, plain: true)
        let start = XNode("w:bookmarkStart", ["w:id": String(bookmarkID), "w:name": String(format: "_TocMM%05d", bookmarkID)])
        let end = XNode("w:bookmarkEnd", ["w:id": String(bookmarkID)])
        bookmarkID += 1
        if let ppr = p.find("w:pPr") { p.insertAfter(ppr, start) } else { p.insert(start, at: 0) }
        p.append(end)
        return p
    }

    private func listItem(_ s: MDBlock) -> XNode {
        let format = (s.ordered ? style.number : style.bullet)
            ?? ParaFormat(model.styles.findRole("list_paragraph") ?? style.bodyFormat.styleID, rpr: style.bodyFormat.rpr)
        let p = paragraph(format, s.inlines)
        guard let ppr = p.find("w:pPr") else { return p }
        let id = listNumber(s, format)
        let numPr = XNode("w:numPr", [:], [XNode("w:ilvl", ["w:val": String(min(s.level, 8))]), XNode("w:numId", ["w:val": id])])
        OOXML.put(ppr, numPr)
        // deeper levels: the numbering's own indent, not the example's
        if s.level > 0 { ppr.removeAll("w:ind") }
        return p
    }

    /// The numbering of a list item: a numbered list starts at 1 for each Markdown list.
    private func listNumber(_ s: MDBlock, _ format: ParaFormat) -> String {
        if let known = listNumbers[s.listID] { return known }
        var base = format.ppr?.find("w:numPr")?.find("w:numId")?.val
        if base == nil {
            base = model.styles.chain(format.styleID).compactMap { $0.element.find("w:pPr")?.find("w:numPr")?.find("w:numId")?.val }.first
        }
        let number: String
        if let base, base != "0" {
            number = s.ordered ? numbering.restart(base) : base
        } else {
            number = numbering.newList(ordered: s.ordered)
        }
        listNumbers[s.listID] = number
        return number
    }

    private func quote(_ s: MDBlock) -> XNode {
        if let q = style.quote { return paragraph(q, s.inlines) }
        let p = paragraph(style.bodyFormat, s.inlines.map { var x = $0; x.italic = true; return x })
        if let ppr = p.find("w:pPr") { OOXML.put(ppr, "w:ind", ["w:left": "567"]) }
        return p
    }

    private func code(_ s: MDBlock) -> [XNode] {
        let format = style.code ?? ParaFormat(style.bodyFormat.styleID)
        return s.text.components(separatedBy: "\n").map { line in
            let p = paragraph(format, line.isEmpty ? [] : [MDInline(text: line, code: true)])
            if let ppr = p.find("w:pPr") {
                OOXML.put(ppr, "w:spacing", ["w:before": "0", "w:after": "0"])
                OOXML.put(ppr, "w:shd", ["w:val": "clear", "w:color": "auto", "w:fill": "F2F2F2"])
            }
            return p
        }
    }

    private var captionFormat: ParaFormat {
        if let c = style.caption { return c }
        let rpr = XNode("w:rPr")
        OOXML.put(rpr, "w:i")
        OOXML.put(rpr, "w:sz", ["w:val": "18"])
        return ParaFormat(model.styles.ensureStyle("Caption", name: "caption", basedOn: style.bodyFormat.styleID, rpr: rpr))
    }

    private func image(_ s: MDBlock) -> [XNode] {
        guard let (data, ext) = images?(s.source) else {
            return [paragraph(style.bodyFormat, [MDInline(text: L("[Afbeelding niet gevonden: \(s.text.isEmpty ? s.source : s.text)]"), italic: true)])]
        }
        let p = paragraph(style.bodyFormat, [])
        if let ppr = p.find("w:pPr") {
            OOXML.put(ppr, "w:keepNext")
            OOXML.put(ppr, "w:jc", ["w:val": "center"])
        }
        p.append(drawingRun(data, ext: ext, description: s.text))
        guard !s.text.isEmpty else { return [p] }
        figure += 1
        let caption = paragraph(captionFormat, [MDInline(text: L("Figuur") + " ")])
        let field = caption.add("w:fldSimple", ["w:instr": " SEQ \(L("Figuur")) \\* ARABIC "])
        field.add("w:r").append(XNode.textElement("w:t", String(figure)))
        append(MDInline(text: ": " + s.text), to: caption, base: captionFormat.newRPr())
        return [p, caption]
    }

    private func drawingRun(_ data: Data, ext: String, description: String) -> XNode {
        let ext = ext.lowercased()
        let name = pkg.uniqueMediaName(ext)
        pkg.setData(name, data)
        pkg.ensureDefaultType(ext, Self.imageTypes[ext] ?? "application/octet-stream")
        let id = pkg.addRelationship(pkg.mainPart, type: OOXML.relImage, target: String(name.dropFirst("word/".count)))
        let (cx, cy) = Self.imageSize(data, maxWidth: widthTwips * Self.emuPerTwip)
        let d = drawingID
        drawingID += 1
        let xmlns = OOXML.drawing.map { ["xmlns:" + $0.key, $0.value] }.reduce(into: [String: String]()) { $0[$1[0]] = $1[1] }
        let inline = XNode("wp:inline", ["distT": "0", "distB": "0", "distL": "0", "distR": "0"])
        inline.add("wp:extent", ["cx": String(cx), "cy": String(cy)])
        inline.add("wp:effectExtent", ["l": "0", "t": "0", "r": "0", "b": "0"])
        inline.add("wp:docPr", ["id": String(d), "name": L("Afbeelding") + " \(d)", "descr": description.isEmpty ? L("Afbeelding") + " \(d)" : description])
        inline.add("wp:cNvGraphicFramePr").add("a:graphicFrameLocks", ["noChangeAspect": "1"])
        let pic = inline.add("a:graphic").add("a:graphicData", ["uri": "http://schemas.openxmlformats.org/drawingml/2006/picture"]).add("pic:pic")
        let nv = pic.add("pic:nvPicPr")
        nv.add("pic:cNvPr", ["id": String(d), "name": (name as NSString).lastPathComponent])
        nv.add("pic:cNvPicPr")
        let fill = pic.add("pic:blipFill")
        fill.add("a:blip", ["r:embed": id])
        fill.add("a:stretch").add("a:fillRect")
        let sp = pic.add("pic:spPr")
        let xfrm = sp.add("a:xfrm")
        xfrm.add("a:off", ["x": "0", "y": "0"])
        xfrm.add("a:ext", ["cx": String(cx), "cy": String(cy)])
        sp.add("a:prstGeom", ["prst": "rect"]).add("a:avLst")
        let run = XNode("w:r")
        // the template's document element need not declare these namespaces
        run.add("w:drawing", xmlns).append(inline)
        return run
    }

    /// The image's size at its own resolution, at most the text width and a bit more than that in height.
    static func imageSize(_ data: Data, maxWidth: Int) -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Double, let h = info[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else {
            return (maxWidth, maxWidth * 6 / 10)
        }
        let dpi = max(info[kCGImagePropertyDPIWidth] as? Double ?? 96, 1)
        let cx = w / dpi * 914_400, cy = h / dpi * 914_400
        let scale = min(1, Double(maxWidth) / cx, Double(maxWidth) * 1.1 / cy)
        return (Int(cx * scale), Int(cy * scale))
    }

    private func table(_ s: MDBlock) -> [XNode] {
        let rows = (s.header.isEmpty ? [] : [s.header]) + s.rows
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return [] }
        let example = style.tableExample
        let tbl = XNode("w:tbl")
        let tblPr = example?.find("w:tblPr")?.copy() ?? XNode("w:tblPr")
        if example?.find("w:tblPr") == nil, let id = model.styles.findRole("table_grid") ?? model.styles.defaultTable {
            OOXML.put(tblPr, "w:tblStyle", ["w:val": id])
        }
        OOXML.put(tblPr, "w:tblW", ["w:w": "5000", "w:type": "pct"])
        tbl.append(tblPr)

        var total = widthTwips
        let grid = example?.find("w:tblGrid")?.findAll("w:gridCol").map { Int($0["w:w"] ?? "") ?? 0 }.reduce(0, +) ?? 0
        if grid > 1000 { total = min(grid, total) }
        let widths = Self.columnWidths(rows, columns, total)
        let tblGrid = tbl.add("w:tblGrid")
        for w in widths { tblGrid.add("w:gridCol", ["w:w": String(w)]) }

        let exampleRows = example?.findAll("w:tr") ?? []
        let headerExample = exampleRows.first
        let bodyExamples = exampleRows.count > 1 ? Array(exampleRows.dropFirst()) : (s.header.isEmpty ? exampleRows : [])
        for (ri, row) in rows.enumerated() {
            let isHeader = !s.header.isEmpty && ri == 0
            let rowExample = isHeader ? headerExample
                : bodyExamples.isEmpty ? nil : bodyExamples[(ri - (s.header.isEmpty ? 0 : 1)) % bodyExamples.count]
            tbl.append(tableRow(row, columns: columns, widths: widths, example: rowExample, isHeader: isHeader))
        }
        // a paragraph after the table, as Word does; otherwise tables next to each other merge
        return [tbl, paragraph(style.bodyFormat, [])]
    }

    private func tableRow(_ cells: [[MDInline]], columns: Int, widths: [Int], example: XNode?, isHeader: Bool) -> XNode {
        let tr = XNode("w:tr")
        let exampleCells = example?.findAll("w:tc") ?? []
        if let trPr = example?.find("w:trPr")?.copy() {
            for t in ["w:trHeight", "w:gridBefore", "w:gridAfter", "w:wBefore", "w:wAfter"] { trPr.removeAll(t) }
            tr.append(trPr)
        } else if isHeader {
            tr.add("w:trPr").add("w:tblHeader")
        }
        for c in 0..<columns {
            let cellExample = exampleCells.isEmpty ? nil : exampleCells[min(c, exampleCells.count - 1)]
            tr.append(tableCell(c < cells.count ? cells[c] : [], width: widths[c], example: cellExample, isHeader: isHeader))
        }
        return tr
    }

    private func tableCell(_ inlines: [MDInline], width: Int, example: XNode?, isHeader: Bool) -> XNode {
        let tc = XNode("w:tc")
        let tcPr = example?.find("w:tcPr")?.copy() ?? XNode("w:tcPr")
        for t in ["w:gridSpan", "w:vMerge", "w:hMerge"] { tcPr.removeAll(t) }
        OOXML.put(tcPr, "w:tcW", ["w:w": String(width), "w:type": "dxa"])
        tc.append(tcPr)
        let exampleP = example?.find("w:p")
        let ppr = exampleP?.find("w:pPr")
        let exampleRun = exampleP?.descendants("w:r").first { $0.has("w:t") }
        var rpr = exampleRun?.find("w:rPr")
        if example == nil && isHeader {
            rpr = XNode("w:rPr")
            OOXML.put(rpr!, "w:b")
        }
        // a line break in a cell becomes a paragraph
        var lines: [[MDInline]] = [[]]
        for i in inlines {
            if i.isBreak { lines.append([]) } else { lines[lines.count - 1].append(i) }
        }
        for line in lines {
            let p = tc.add("w:p")
            if let ppr { p.append(ppr.copy()) }
            for i in line { append(i, to: p, base: rpr?.copy()) }
        }
        return tc
    }

    private static func columnWidths(_ rows: [[[MDInline]]], _ columns: Int, _ total: Int) -> [Int] {
        var lengths = [Int](repeating: 10, count: columns)
        for r in rows {
            for (i, cell) in r.enumerated() where i < columns {
                lengths[i] = max(lengths[i], min(cell.map(\.text.count).reduce(0, +), 60))
            }
        }
        let sum = lengths.reduce(0, +)
        var widths = lengths.map { total * $0 / sum }
        widths[columns - 1] += total - widths.reduce(0, +)
        return widths
    }

    // MARK: - paragraphs and runs

    func paragraph(_ format: ParaFormat, _ inlines: [MDInline], plain: Bool = false) -> XNode {
        let p = XNode("w:p")
        p.append(format.newPPr())
        for i in inlines { append(i, to: p, base: format.newRPr(), plain: plain) }
        return p
    }

    private func append(_ i: MDInline, to parent: XNode, base: XNode?, plain: Bool = false) {
        if i.isBreak {
            parent.add("w:r").add("w:br")
            return
        }
        guard !i.text.isEmpty else { return }
        let r = Self.run(i.text, base: base, bold: i.bold && !plain, italic: i.italic && !plain, code: i.code, strike: i.strike)
        guard let link = i.link, !plain else { parent.append(r); return }
        let h = parent.add("w:hyperlink", ["w:history": "1"])
        if link.hasPrefix("#") {
            h["w:anchor"] = String(link.dropFirst())
        } else {
            h["r:id"] = pkg.addRelationship(pkg.mainPart, type: OOXML.relHyperlink, target: link, external: true)
            // the template's document element need not declare this namespace
            if pkg.document["xmlns:r"] == nil { pkg.document["xmlns:r"] = OOXML.drawing["r"] }
        }
        let rpr: XNode
        if let existing = r.find("w:rPr") { rpr = existing } else {
            rpr = XNode("w:rPr")
            r.insert(rpr, at: 0)
        }
        if let id = model.styles.findRole("hyperlink") {
            OOXML.put(rpr, "w:rStyle", ["w:val": id])
        } else {
            OOXML.put(rpr, "w:color", ["w:val": "0563C1"])
            OOXML.put(rpr, "w:u", ["w:val": "single"])
        }
        h.append(r)
    }

    static func run(_ text: String, base: XNode?, bold: Bool = false, italic: Bool = false, code: Bool = false, strike: Bool = false) -> XNode {
        let r = XNode("w:r")
        let rpr = base ?? XNode("w:rPr")
        if bold { OOXML.put(rpr, "w:b") }
        if italic { OOXML.put(rpr, "w:i") }
        if strike { OOXML.put(rpr, "w:strike") }
        if code { OOXML.put(rpr, "w:rFonts", ["w:ascii": "Consolas", "w:hAnsi": "Consolas", "w:cs": "Consolas"]) }
        if !rpr.elements.isEmpty { r.append(rpr) }
        for (n, part) in text.components(separatedBy: "\t").enumerated() {
            if n > 0 { r.add("w:tab") }
            if !part.isEmpty { r.append(XNode.textElement("w:t", part)) }
        }
        return r
    }
}

/// Adds to numbering.xml, and creates it for a template without lists.
final class NumberingWriter {
    private let pkg: DocxPackage
    private var part: String?

    init(_ pkg: DocxPackage) {
        self.pkg = pkg
        part = pkg.relatedPart(OOXML.relNumbering)
    }

    private func root() -> XNode {
        if let part, let x = pkg.xml(part) { return x }
        let name = "word/numbering.xml"
        let x = XNode("w:numbering", ["xmlns:w": OOXML.wordNamespace])
        pkg.setXML(name, x)
        pkg.addRelationship(pkg.mainPart, type: OOXML.relNumbering, target: "numbering.xml")
        pkg.ensureOverrideType(name, OOXML.ctNumbering)
        part = name
        return x
    }

    private func next(_ nodes: [XNode], _ attribute: String) -> Int {
        (nodes.compactMap { $0[attribute].flatMap(Int.init) }.max() ?? 0) + 1
    }

    func restart(_ id: String) -> String {
        let r = root()
        let nums = r.findAll("w:num")
        guard let source = nums.first(where: { $0["w:numId"] == id }), let abstract = source.find("w:abstractNumId")?.val else { return id }
        let new = String(next(nums, "w:numId"))
        let n = r.add("w:num", ["w:numId": new])
        n.add("w:abstractNumId", ["w:val": abstract])
        n.add("w:lvlOverride", ["w:ilvl": "0"]).add("w:startOverride", ["w:val": "1"])
        return new
    }

    func newList(ordered: Bool) -> String {
        let r = root()
        let abstracts = r.findAll("w:abstractNum")
        let abstractID = String(next(abstracts, "w:abstractNumId"))
        let a = XNode("w:abstractNum", ["w:abstractNumId": abstractID])
        a.add("w:multiLevelType", ["w:val": "hybridMultilevel"])
        let bullets = ["•", "◦", "▪"], formats = ["decimal", "lowerLetter", "lowerRoman"]
        for i in 0..<9 {
            let l = a.add("w:lvl", ["w:ilvl": String(i)])
            l.add("w:start", ["w:val": "1"])
            l.add("w:numFmt", ["w:val": ordered ? formats[i % 3] : "bullet"])
            l.add("w:lvlText", ["w:val": ordered ? "%\(i + 1)." : bullets[i % 3]])
            l.add("w:lvlJc", ["w:val": "left"])
            l.add("w:pPr").add("w:ind", ["w:left": String(360 * (i + 1)), "w:hanging": "360"])
        }
        // abstract numberings come before the numberings
        if let last = abstracts.last { r.insertAfter(last, a) }
        else if let first = r.find("w:num") { r.insertBefore(first, a) }
        else { r.append(a) }
        let id = String(next(r.findAll("w:num"), "w:numId"))
        r.add("w:num", ["w:numId": id]).add("w:abstractNumId", ["w:val": abstractID])
        return id
    }
}
