import Foundation

/// OOXML names the Word engine uses.
enum OOXML {
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let relImage = relationships + "image"
    static let relHyperlink = relationships + "hyperlink"
    static let relNumbering = relationships + "numbering"
    static let relOfficeDocument = relationships + "officeDocument"
    static let relStyles = relationships + "styles"
    static let relSettings = relationships + "settings"
    static let ctNumbering = "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"
    static let ctDocument = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
    static let drawing = ["wp": "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
                          "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
                          "pic": "http://schemas.openxmlformats.org/drawingml/2006/picture",
                          "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"]

    /// The order of the children of the property containers that are changed: Word refuses a document with another order.
    private static let order: [String: String] = [
        "w:pPr": "pStyle keepNext keepLines pageBreakBefore framePr widowControl numPr suppressLineNumbers pBdr shd tabs "
            + "suppressAutoHyphens kinsoku wordWrap overflowPunct topLinePunct autoSpaceDE autoSpaceDN bidi "
            + "adjustRightInd snapToGrid spacing ind contextualSpacing mirrorIndents suppressOverlap jc textDirection "
            + "textAlignment textboxTightWrap outlineLvl divId cnfStyle rPr sectPr pPrChange",
        "w:rPr": "rStyle rFonts b bCs i iCs caps smallCaps strike dstrike outline shadow emboss imprint noProof snapToGrid "
            + "vanish webHidden color spacing w kern position sz szCs highlight u effect bdr shd fitText vertAlign rtl cs "
            + "em lang eastAsianLayout specVanish oMath",
        "w:numPr": "ilvl numId numberingChange ins",
        "w:tcPr": "cnfStyle tcW gridSpan hMerge vMerge tcBorders shd noWrap tcMar textDirection tcFitText vAlign hideMark",
        "w:tblPr": "tblStyle tblpPr tblOverlap bidiVisual tblStyleRowBandSize tblStyleColBandSize tblW jc tblCellSpacing "
            + "tblInd tblBorders shd tblLayout tblCellMar tblLook tblCaption tblDescription",
        "w:settings": "writeProtection view zoom removePersonalInformation removeDateAndTime doNotDisplayPageBoundaries "
            + "displayBackgroundShape printPostScriptOverText printFractionalCharacterWidth printFormsData "
            + "embedTrueTypeFonts embedSystemFonts saveSubsetFonts saveFormsData mirrorMargins alignBordersAndEdges "
            + "bordersDoNotSurroundHeader bordersDoNotSurroundFooter gutterAtTop hideSpellingErrors "
            + "hideGrammaticalErrors activeWritingStyle proofState formsDesign attachedTemplate linkStyles "
            + "stylePaneFormatFilter stylePaneSortMethod documentType mailMerge revisionView trackRevisions "
            + "doNotTrackMoves doNotTrackFormatting documentProtection autoFormatOverride styleLockTheme "
            + "styleLockQFSet defaultTabStop autoHyphenation consecutiveHyphenLimit hyphenationZone "
            + "doNotHyphenateCaps showEnvelope summaryLength clickAndTypeStyle defaultTableStyle evenAndOddHeaders "
            + "bookFoldRevPrinting bookFoldPrinting bookFoldPrintingSheets drawingGridHorizontalSpacing "
            + "drawingGridVerticalSpacing displayHorizontalDrawingGridEvery displayVerticalDrawingGridEvery "
            + "doNotUseMarginsForDrawingGridOrigin drawingGridHorizontalOrigin drawingGridVerticalOrigin "
            + "doNotShadeFormData noPunctuationKerning characterSpacingControl printTwoOnOne "
            + "strictFirstAndLastChars noLineBreaksAfter noLineBreaksBefore savePreviewPicture "
            + "doNotValidateAgainstSchema saveInvalidXml ignoreMixedContent alwaysShowPlaceholderText "
            + "doNotDemarcateInvalidXml saveXmlDataOnly useXSLTWhenSaving saveThroughXslt showXMLTags "
            + "alwaysMergeEmptyNamespace updateFields hdrShapeDefaults footnotePr endnotePr compat docVars rsids "
            + "mathPr attachedSchema themeFontLang clrSchemeMapping doNotIncludeSubdocsInStats "
            + "doNotAutoCompressPictures forceUpgrade captions readModeInkLockDown smartTagType schemaLibrary "
            + "shapeDefaults doNotEmbedSmartTags decimalSymbol listSeparator",
    ]
    static let orderIndex: [String: [String: Int]] = order.mapValues { names in
        Dictionary(uniqueKeysWithValues: names.split(separator: " ").enumerated().map { ("w:" + $1, $0) })
    }

    /// "word/../customXml/a.xml" -> "customXml/a.xml"; NSString's standardizingPath leaves a relative path as it is.
    static func normalized(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = out.popLast() } else { out.append(part) }
        }
        return out.joined(separator: "/")
    }

    /// Puts `child` in a property container at its place in the schema, in place of one with the same name.
    @discardableResult
    static func put(_ parent: XNode, _ child: XNode) -> XNode {
        let index = orderIndex[parent.name] ?? [:]
        parent.removeAll(child.name)
        let position = index[child.name] ?? 10_000
        if let next = parent.elements.first(where: { (index[$0.name] ?? 10_000) > position }) {
            parent.insertBefore(next, child)
        } else {
            parent.append(child)
        }
        return child
    }

    @discardableResult
    static func put(_ parent: XNode, _ name: String, _ attributes: [String: String] = [:]) -> XNode {
        put(parent, XNode(name, attributes))
    }
}

/// A .docx kept part by part: only the parts that are read as XML are written anew; the theme, fonts, images and
/// everything else go back byte for byte. That keeps the house style intact.
final class DocxPackage {
    private var order: [String] = []
    private var raw: [String: Data] = [:]
    private var parsed: [String: XNode] = [:]
    private(set) var mainPart = "word/document.xml"

    convenience init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    init(data: Data) throws {
        for (name, content) in try Zip.read(data) where raw[name] == nil {
            order.append(name)
            raw[name] = content
        }
        if let rels = raw["_rels/.rels"], let root = try? XNode.parse(rels),
           let target = root.elements.first(where: { $0["Type"] == OOXML.relOfficeDocument })?["Target"] {
            mainPart = target.hasPrefix("/") ? String(target.dropFirst()) : target
        }
        guard let main = raw[mainPart] else { throw Zip.Failure(L("Dit is geen Word-document.")) }
        let root: XNode
        do { root = try XNode.parse(main) } catch { throw Zip.Failure(L("Dit Word-document is beschadigd.")) }
        // the code assumes the prefix w: of normal Word files; Strict Open XML has another namespace
        guard root["xmlns:w"] == OOXML.wordNamespace, root.find("w:body") != nil else {
            throw Zip.Failure(L("Dit Word-document gebruikt een indeling die de app niet kent (bijvoorbeeld Strict Open XML). Sla het in Word op als gewoon .docx."))
        }
        parsed[mainPart] = root
    }

    /// A new package from its parts, for the built-in house style.
    init(parts: [(String, String)]) throws {
        for (name, text) in parts {
            order.append(name)
            raw[name] = Data(text.utf8)
        }
        parsed[mainPart] = try XNode.parse(raw[mainPart] ?? Data())
    }

    func has(_ name: String) -> Bool { raw[name] != nil || parsed[name] != nil }
    var names: [String] { order }

    func data(_ name: String) -> Data? {
        if let x = parsed[name] { return x.serialized() }
        return raw[name]
    }

    func setData(_ name: String, _ data: Data) {
        parsed[name] = nil
        if raw[name] == nil { order.append(name) }
        raw[name] = data
    }

    /// The part as a tree; nil when it is missing or not XML.
    func xml(_ name: String) -> XNode? {
        if let x = parsed[name] { return x }
        guard let d = raw[name], let root = try? XNode.parse(d) else { return nil }
        parsed[name] = root
        return root
    }

    func setXML(_ name: String, _ root: XNode) {
        if raw[name] == nil {
            order.append(name)
            raw[name] = Data()
        }
        parsed[name] = root
    }

    var document: XNode { xml(mainPart)! }
    var body: XNode { document.find("w:body")! }

    func toData() -> Data {
        // a template's main part declares itself as a template, and then Word does not open the .docx
        if let types = xml("[Content_Types].xml"),
           let main = types.findAll("Override").first(where: { $0["PartName"] == "/" + mainPart }),
           main["ContentType"]?.contains(".template.") == true {
            main["ContentType"] = OOXML.ctDocument
        }
        // [Content_Types].xml first, as Word expects
        let names = order.filter { $0 == "[Content_Types].xml" } + order.filter { $0 != "[Content_Types].xml" }
        return Zip.write(names.compactMap { n in data(n).map { (n, $0) } })
    }

    // MARK: - relationships

    private func relsName(_ part: String) -> String {
        let ns = part as NSString
        return (ns.deletingLastPathComponent as NSString).appendingPathComponent("_rels/" + ns.lastPathComponent + ".rels")
    }

    private func rels(_ part: String) -> XNode {
        let name = relsName(part)
        if let x = xml(name) { return x }
        let root = XNode("Relationships", ["xmlns": "http://schemas.openxmlformats.org/package/2006/relationships"])
        setXML(name, root)
        // the extension needs a content type
        ensureDefaultType("rels", "application/vnd.openxmlformats-package.relationships+xml")
        return root
    }

    func relationship(_ part: String, _ id: String) -> (type: String, target: String, external: Bool)? {
        guard let r = rels(part).elements.first(where: { $0["Id"] == id }) else { return nil }
        return (r["Type"] ?? "", r["Target"] ?? "", r["TargetMode"] == "External")
    }

    func partForRelationship(_ part: String, _ id: String) -> String? {
        guard let r = relationship(part, id), !r.external else { return nil }
        return resolve(part, r.target)
    }

    private func resolve(_ part: String, _ target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        let dir = (part as NSString).deletingLastPathComponent
        return OOXML.normalized((dir as NSString).appendingPathComponent(target))
    }

    func relatedPart(_ type: String) -> String? {
        guard let r = rels(mainPart).elements.first(where: { $0["Type"] == type && $0["TargetMode"] != "External" }),
              let target = r["Target"] else { return nil }
        return resolve(mainPart, target)
    }

    @discardableResult
    func addRelationship(_ part: String, type: String, target: String, external: Bool = false) -> String {
        let root = rels(part)
        if let same = root.elements.first(where: { $0["Type"] == type && $0["Target"] == target }), let id = same["Id"] { return id }
        let taken = Set(root.elements.compactMap { $0["Id"] })
        var n = 1
        while taken.contains("rId\(n)") { n += 1 }
        let r = root.add("Relationship", ["Id": "rId\(n)", "Type": type, "Target": target])
        if external { r["TargetMode"] = "External" }
        return "rId\(n)"
    }

    // MARK: - content types

    func ensureDefaultType(_ ext: String, _ type: String) {
        guard let types = xml("[Content_Types].xml"),
              !types.findAll("Default").contains(where: { $0["Extension"]?.lowercased() == ext.lowercased() }) else { return }
        // defaults come before overrides for strict readers
        types.insert(XNode("Default", ["Extension": ext, "ContentType": type]), at: 0)
    }

    func ensureOverrideType(_ part: String, _ type: String) {
        guard let types = xml("[Content_Types].xml"),
              !types.findAll("Override").contains(where: { $0["PartName"] == "/" + part }) else { return }
        types.add("Override", ["PartName": "/" + part, "ContentType": type])
    }

    func uniqueMediaName(_ ext: String) -> String {
        var n = 1
        while has("word/media/mm_image\(n).\(ext)") { n += 1 }
        return "word/media/mm_image\(n).\(ext)"
    }
}
