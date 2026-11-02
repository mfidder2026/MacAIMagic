import XCTest
import AppKit
@testable import MacAIMagic

/// The Word engine on a template with a cover, a table of contents, numbered headings and a table.
/// MACAIMAGIC_DOCX_OUT=<dir> keeps the results, to check them with other programs.
final class DocumentEngineTests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sjabloon.docx")

    private static let markdown = """
    ---
    klant: RIVM
    versie: 0.1
    datum: 1 jan
    auteur: MF
    ---

    # Inleiding
    ## 1.1 Aanleiding
    Tekst met **vet**, *cursief*, `code` en een [link](https://example.org).

    - punt
      - subpunt
    - punt twee

    1. eerste
    2. tweede

    # Bevindingen
    | Thema | Bevinding |
    |---|---|
    | IAM | Geen MFA |

    ![Plaat](plaat.png)

    > Citaat

    ```
    code regel
    ```
    """

    private func template() throws -> Data { try Data(contentsOf: Self.fixture) }

    private func png() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 3,
                                     hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return image.representation(using: .png, properties: [:])!
    }

    private func output(_ name: String) -> URL {
        let dir = ProcessInfo.processInfo.environment["MACAIMAGIC_DOCX_OUT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("\(name).docx")
    }

    func testZipKeepsEveryPart() throws {
        let data = try template()
        let again = try Zip.read(Zip.write(try Zip.read(data)))
        let original = try Zip.read(data)
        XCTAssertEqual(again.map(\.name), original.map(\.name))
        for (a, b) in zip(again, original) { XCTAssertEqual(a.data, b.data, a.name) }
    }

    func testPartsThatAreNotTouchedStayByteForByte() throws {
        let original = Dictionary(uniqueKeysWithValues: try Zip.read(try template()).map { ($0.name, $0.data) })
        let out = output("onaangeroerd")
        _ = try DocxCompose.build(template: try template(), markdown: "# Titel\n\nTekst.", to: out)
        let result = Dictionary(uniqueKeysWithValues: try Zip.read(try Data(contentsOf: out)).map { ($0.name, $0.data) })
        for name in ["word/theme/theme1.xml", "word/fontTable.xml", "word/webSettings.xml", "docProps/thumbnail.jpeg", "customXml/item1.xml"] {
            XCTAssertEqual(result[name], original[name], name)
        }
    }

    func testXMLKeepsNamespacesAndText() throws {
        let source = "<a:r xmlns:a=\"urn:a\" a:x=\"1 &amp; 2\"><!-- c --><a:t xml:space=\"preserve\"> x &lt; y </a:t></a:r>"
        let root = try XNode.parse(Data(source.utf8))
        XCTAssertEqual(root["xmlns:a"], "urn:a")
        XCTAssertEqual(root["a:x"], "1 & 2")
        XCTAssertEqual(root.find("a:t")?.text, " x < y ")
        let again = try XNode.parse(root.serialized())
        XCTAssertEqual(again.signature, root.signature)
    }

    func testOutlineOfTheTemplate() throws {
        let model = DocModel(try DocxPackage(data: try template()))
        let outline = model.outline()
        XCTAssertEqual(outline.first?.number, "1")
        XCTAssertEqual(outline.first?.title, "Inleiding")
        XCTAssertTrue(outline.contains { $0.number == "1.2" && $0.title == "Doel en scope" })
    }

    func testNewDocumentInTheHouseStyle() throws {
        let out = output("nieuw")
        let report = try DocxCompose.build(template: try template(), markdown: Self.markdown, to: out, images: { [png] in $0 == "plaat.png" ? (png(), "png") : nil })
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.tocEntries, 3)

        let pkg = try DocxPackage(url: out)
        let model = DocModel(pkg)
        XCTAssertEqual(Array(model.outline().map(\.title).prefix(2)), ["Inleiding", "Aanleiding"], "the template numbers headings itself")
        let text = model.blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("RIVM"))
        XCTAssertFalse(text.contains("{{"))
        XCTAssertFalse(text.contains("[Beschrijf"))
        let kinds = model.blocks.map(\.kind)
        for k in [Block.Kind.heading, .list, .table, .paragraph, .toc, .image] { XCTAssertTrue(kinds.contains(k), "\(k)") }
        XCTAssertFalse(pkg.xml("word/header1.xml")?.allText.contains("{{klant}}") ?? false)
        XCTAssertEqual(DocxValidator.validate(try Data(contentsOf: out)), [])
    }

    func testTableTakesTheLookOfTheTemplate() throws {
        let source = DocModel(try DocxPackage(data: try template())).blocks.first { $0.kind == .table }
        let wanted = source?.element.findAll("w:tr").first?.findAll("w:tc").first?.find("w:tcPr")?.find("w:shd")?["w:fill"]
        XCTAssertNotNil(wanted, "the template has a coloured header row")
        let out = output("tabel")
        _ = try DocxCompose.build(template: try template(), markdown: "# Kop\n\n| A | B |\n|---|---|\n| 1 | 2 |\n", to: out)
        let table = DocModel(try DocxPackage(url: out)).blocks.first { $0.kind == .table }
        XCTAssertEqual(table?.element.findAll("w:tr").first?.findAll("w:tc").first?.find("w:tcPr")?.find("w:shd")?["w:fill"], wanted)
        XCTAssertEqual(table?.rows, [["A", "B"], ["1", "2"]])
    }

    func testTemplateBecomesADraftAndBack() throws {
        let draft = try DocxCompose.draft(template: try template())
        let parsed = DocumentDraft(markdown: draft)
        let keys = Set(parsed.fields.map { DocxFields.normalized($0.key) })
        XCTAssertTrue(keys.isSuperset(of: ["klant", "versie"]), "\(keys)")
        XCTAssertTrue(parsed.body.contains("# Inleiding"))
        XCTAssertTrue(parsed.body.contains("<!-- "), "the template's instructions stay for the model")
        XCTAssertEqual(DocumentDraft(markdown: draft), parsed)

        let out = output("terug")
        let report = try DocxCompose.build(template: try template(), markdown: draft, to: out)
        XCTAssertEqual(report.problems, [])
        let text = DocModel(try DocxPackage(url: out)).blocks.map(\.text).joined(separator: "\n")
        XCTAssertFalse(text.contains("instructie:"), "comments stay out of the document")
    }

    func testEmptyFieldsAreReported() throws {
        let report = try DocxCompose.build(template: try template(), markdown: "---\nklant:\nversie: [Versie]\nauteur: MF\n---\n\n# Kop\n", to: output("leeg"))
        XCTAssertTrue(report.warnings.contains { $0.contains("klant") && $0.contains("versie") && !$0.contains("auteur") })
    }

    func testPlainStyleWithoutTemplate() throws {
        let out = output("eenvoudig")
        let report = try DocxCompose.build(template: nil, markdown: "---\ntitel: Onderzoek naar SSD's\n---\n\n# Antwoord\n\nTekst [1].\n\n## Details\n\n- punt\n\n1. een\n\n# Bronnen\n\n1. [Bron](https://example.org)\n", to: out)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.tocEntries, 3)
        let model = DocModel(try DocxPackage(url: out))
        XCTAssertEqual(model.blocks.first?.text, "Onderzoek naar SSD's")
        XCTAssertEqual(model.outline().map(\.title), ["Antwoord", "Details", "Bronnen"])
        XCTAssertTrue(model.blocks.contains { $0.spans.contains { $0.link == "https://example.org" } })
    }

    func testTemplateFileBecomesADocument() throws {
        // a .dotx declares itself as a template, and Word does not open a .docx that does
        var parts = try Zip.read(try template())
        let i = try XCTUnwrap(parts.firstIndex { $0.name == "[Content_Types].xml" })
        let types = String(decoding: parts[i].data, as: UTF8.self).replacingOccurrences(of: "document.main+xml", with: "template.main+xml")
        XCTAssertTrue(types.contains("template.main+xml"))
        parts[i].data = Data(types.utf8)
        let out = output("uit-dotx")
        _ = try DocxCompose.build(template: Zip.write(parts), markdown: "# Kop\n", to: out)
        let result = try Zip.read(try Data(contentsOf: out)).first { $0.name == "[Content_Types].xml" }
        XCTAssertFalse(String(decoding: result!.data, as: UTF8.self).contains("template.main+xml"))
    }

    func testFilesThatAreNotWordAreRefused() {
        XCTAssertThrowsError(try DocxPackage(data: Data("geen zip".utf8)))
        XCTAssertThrowsError(try DocxPackage(data: Zip.write([("a.txt", Data("x".utf8))])))
    }

    func testValidatorFindsWhatWordRefuses() throws {
        var parts = try Zip.read(try template())
        let i = try XCTUnwrap(parts.firstIndex { $0.name == "word/document.xml" })
        let root = try XNode.parse(parts[i].data)
        let rpr = XNode("w:rPr", [:], [XNode("w:sz", ["w:val": "20"]), XNode("w:b")])
        root.find("w:body")?.insert(XNode("w:p", [:], [XNode("w:r", [:], [rpr])]), at: 0)
        parts[i].data = root.serialized()
        XCTAssertTrue(DocxValidator.validate(Zip.write(parts)).contains { $0.contains("w:rPr") })
    }

    // MARK: - Markdown

    func testMarkdownBlocks() {
        let blocks = MarkdownBlocks.parse("""
        # Kop één
        Regel een
        regel twee

        - a
          - b
        - c

        1. x
        2. y

        | K1 | K2 |
        |----|:--:|
        | p \\| q | r<br>s |

        > quote

        <!-- instructie: niet tonen -->

        <!-- pagebreak -->

        ![Plaat](p.png)

        Figuur 1: uitleg

        ---

        ```swift
        let a = 1
        ```
        """)
        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph, .list, .list, .list, .list, .list, .table, .quote, .pageBreak, .image, .caption, .code])
        XCTAssertEqual(blocks[1].plain, "Regel een regel twee")
        XCTAssertEqual(blocks[3].level, 1)
        XCTAssertEqual(blocks[2].listID, blocks[4].listID)
        XCTAssertNotEqual(blocks[3].listID, blocks[2].listID)
        XCTAssertTrue(blocks[5].ordered)
        XCTAssertEqual(blocks[7].header.count, 2)
        XCTAssertEqual(blocks[7].rows[0][0].map(\.text).joined(), "p | q")
        XCTAssertTrue(blocks[7].rows[0][1].contains { $0.isBreak })
        XCTAssertEqual(blocks[12].text, "let a = 1")
    }

    func testMarkdownInlines() {
        let parts = MarkdownBlocks.inlines("a **b** *c* ***d*** `e*f` ~~g~~ [h **i**](http://x) 2 * 3 snake_case_naam \\*j\\* [1]")
        XCTAssertEqual(parts.map(\.text).joined(), "a b c d e*f g h i 2 * 3 snake_case_naam *j* [1]")
        XCTAssertTrue(parts.first { $0.text == "b" }?.bold == true)
        XCTAssertTrue(parts.first { $0.text == "c" }?.italic == true)
        let d = parts.first { $0.text == "d" }
        XCTAssertTrue(d?.bold == true && d?.italic == true)
        XCTAssertTrue(parts.first { $0.text == "e*f" }?.code == true)
        XCTAssertTrue(parts.first { $0.text == "g" }?.strike == true)
        XCTAssertEqual(parts.first { $0.text == "i" }?.link, "http://x")
        XCTAssertTrue(parts.first { $0.text == "i" }?.bold == true)
    }
}
