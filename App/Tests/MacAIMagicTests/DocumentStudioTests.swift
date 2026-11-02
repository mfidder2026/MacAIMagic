import XCTest
import AppKit
@testable import MacAIMagic

/// Answers like a local model, by what the request asks. It also remembers the requests.
final class FakeModel: URLProtocol {
    nonisolated(unsafe) static var requests: [(host: String, body: [String: Any])] = []
    nonisolated(unsafe) static var answer: (String, String) -> String = { _, _ in "" }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".model.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: 1 << 20)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        Self.requests.append((request.url?.host ?? "", body))
        let text = Self.answer(messages.first?["content"] as? String ?? "", messages.last?["content"] as? String ?? "")
        let chunk: [String: Any] = ["choices": [["delta": ["content": text], "finish_reason": "stop"]]]
        let sse = "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class DocumentStudioTests: XCTestCase {
    private var folder: URL!
    private var studio: DocumentStudio!
    private var searched: [String] = []
    private var failingModel = false

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Settings.shared.language = "nl"     // the fake model recognizes the requests by their Dutch text
        URLProtocol.registerClass(FakeModel.self)
        FakeModel.requests = []
        searched = []
        studio = DocumentStudio(folder: folder)
        studio.endpoint = { role in
            (URL(string: role == .fast ? "http://fast.model.test" : "http://heavy.model.test")!, role == .fast ? "snel" : "zwaar")
        }
        studio.searchWeb = { [weak self] q in
            self?.searched.append(q)
            return [WebTools.Hit(title: "Bron A", url: "https://a.example/1", snippet: ""),
                    WebTools.Hit(title: "Bron B", url: "https://b.example/2", snippet: ""),
                    WebTools.Hit(title: "Kapot", url: "https://kapot.example", snippet: ""),
                    WebTools.Hit(title: "Ruis", url: "https://ruis.example", snippet: "")]
        }
        studio.fetchPage = { url in
            if url.contains("kapot") { throw URLError(.cannotFindHost) }
            if url.contains("ruis") { return ("Ruis", "Recept voor appeltaart.") }
            return (url.contains("a.example") ? "Bron A" : "Bron B", "Inhoud van \(url): de snelheid is 7 GB/s.")
        }
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(FakeModel.self)
        try? FileManager.default.removeItem(at: folder)
    }

    private func waitUntilDone() async throws {
        let start = Date()
        while studio.busy && Date().timeIntervalSince(start) < 20 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(studio.busy)
    }

    private func answerLikeResearch() {
        FakeModel.answer = { system, user in
            if system.contains("zoekvragen") { return "1. snelheid ssd mac\n- ssd mac test@voorbeeld.nl\n" }
            if system.contains("webpagina") { return user.contains("appeltaart") ? "NIETS" : "De snelheid is 7 GB/s." }
            return "## Samenvatting\n\nDe snelheid is 7 GB/s [2]. Dat bevestigt ook [1, 2]. Een verzonnen feit [9]. Volgens bron 2 is dat veel."
        }
    }

    func testResearchEndsAtADraftWithItsSources() async throws {
        answerLikeResearch()
        studio.research(question: "Hoe snel is de SSD? Mail naar piet@voorbeeld.nl")
        try await waitUntilDone()
        XCTAssertNil(studio.problem)

        // a draft on disk, and no document yet: that waits for the user
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".md") }.count, 1)
        XCTAssertEqual(files.filter { $0.hasSuffix(".docx") }.count, 0)

        let draft = DocumentDraft(markdown: studio.text)
        XCTAssertEqual(draft.fields.first?.key, "titel")
        // in the order the text uses them: B first, the made-up one gone
        XCTAssertTrue(draft.body.contains("7 GB/s [1]."), draft.body)
        XCTAssertTrue(draft.body.contains("[2, 1]"), draft.body)
        XCTAssertFalse(draft.body.contains("[9]"))
        XCTAssertTrue(draft.body.contains("1. [Bron B](https://b.example/2)"), draft.body)
        XCTAssertTrue(draft.body.contains("2. [Bron A](https://a.example/1)"), draft.body)
        XCTAssertFalse(draft.body.contains("ruis.example"))
        XCTAssertTrue(studio.notes.contains { $0.contains("[9]") })
        XCTAssertTrue(studio.notes.contains { $0.contains("'bron 3'") }, "a number in words no longer matches the list")
        XCTAssertTrue(studio.notes.contains { $0.contains("2") }, "the two pages that gave nothing are mentioned")

        // nothing personal in what went to the search engine
        XCTAssertFalse(searched.isEmpty)
        XCTAssertFalse(searched.joined().contains("@"), "\(searched)")
    }

    func testFastModelReadsAndHeavyModelWrites() async throws {
        answerLikeResearch()
        studio.research(question: "Hoe snel is de SSD?")
        try await waitUntilDone()
        let hosts = FakeModel.requests.map(\.host)
        XCTAssertEqual(hosts.last, "heavy.model.test")
        XCTAssertEqual(hosts.dropLast().filter { $0 != "fast.model.test" }, [])
        XCTAssertGreaterThan(hosts.count, 2)
        // text from the web reaches a model without tools, so a page cannot make it do anything
        XCTAssertTrue(FakeModel.requests.allSatisfy { $0.body["tools"] == nil })
    }

    func testTheListOfSourcesIsNoReasonForAWarning() async throws {
        FakeModel.answer = { system, user in
            if system.contains("zoekvragen") { return "ssd" }
            if system.contains("webpagina") { return "Een feit." }
            return "Een feit [1]."
        }
        studio.research(question: "Hoe snel")
        try await waitUntilDone()
        XCTAssertEqual(studio.notes.filter { $0.contains("'bron 3'") }, [])
    }

    func testResearchThatFindsNothingWritesNothing() async throws {
        answerLikeResearch()
        studio.searchWeb = { _ in [] }
        studio.research(question: "Iets onvindbaars")
        try await waitUntilDone()
        XCTAssertNotNil(studio.problem)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".md") }, [])
    }

    func testAnEngineThatFailsIsNotCalledAnUnreadablePage() async throws {
        answerLikeResearch()
        var calls = 0
        studio.endpoint = { _ in
            calls += 1
            if calls > 1 { return (URL(string: "http://127.0.0.1:1")!, "weg") }
            return (URL(string: "http://fast.model.test")!, "snel")
        }
        studio.research(question: "Hoe snel is de SSD?")
        try await waitUntilDone()
        XCTAssertNotNil(studio.problem)
    }

    func testDeliverMakesADocumentAndKeepsTheOldOne() async throws {
        answerLikeResearch()
        studio.research(question: "Hoe snel is de SSD")
        try await waitUntilDone()
        studio.deliver()
        let first = try XCTUnwrap(studio.report?.url)
        XCTAssertEqual(studio.report?.problems, [])
        let model = DocModel(try DocxPackage(url: first))
        XCTAssertEqual(model.blocks.first?.text, "Hoe snel is de SSD")
        XCTAssertEqual(model.outline().map(\.title), ["Samenvatting", "Bronnen"])
        studio.deliver()
        XCTAssertNotEqual(studio.report?.url, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testTemplateStaysInTheProject() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sjabloon.docx")
        studio.useTemplate(source)
        XCTAssertEqual(studio.template?.lastPathComponent, "huisstijl.docx")
        studio.newDraft(name: "Rapport")
        XCTAssertTrue(studio.text.contains("# Inleiding"))
        XCTAssertEqual(studio.selected?.lastPathComponent, "Rapport.md")
        XCTAssertEqual(studio.drafts.map(\.lastPathComponent), ["Rapport.md"])

        let bad = folder.appendingPathComponent("geen-word.docx")
        try Data("geen zip".utf8).write(to: bad)
        studio.useTemplate(bad)
        XCTAssertNotNil(studio.problem)
        XCTAssertEqual(studio.template?.lastPathComponent, "huisstijl.docx", "a bad file does not replace the house style")
    }

    func testWritingFollowsTheTemplateSections() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sjabloon.docx")
        studio.useTemplate(source)
        studio.newDraft(name: "Rapport")
        let titles = DraftSections.list(studio.text).map(\.title)
        XCTAssertGreaterThan(titles.count, 3)
        FakeModel.answer = { system, user in
            if system.contains("voorblad") { return "klant: RIVM\nversie: onbekend veld is hier wel\nverzonnen: nee" }
            // a model that adds a heading must not shift the sections
            return "### Extra kop\n\nTekst voor de sectie."
        }
        studio.writeDraft(brief: "Rapport voor RIVM")
        try await waitUntilDone()
        XCTAssertNil(studio.problem)
        XCTAssertEqual(DraftSections.list(studio.text).map(\.title), titles, "the template's structure stays")
        XCTAssertFalse(studio.text.contains("<!-- "), "instructions are replaced by text")
        XCTAssertTrue(studio.text.contains("**Extra kop**"))
        XCTAssertEqual(DocumentDraft(markdown: studio.text).fields.first { DocxFields.normalized($0.key) == "klant" }?.value, "RIVM")
        XCTAssertNil(DocumentDraft(markdown: studio.text).fields.first { $0.key == "verzonnen" })
        studio.deliver()
        XCTAssertEqual(studio.report?.problems, [])
    }

    func testActionWorksOnTheSectionAtTheCursorAndCanBeUndone() async throws {
        studio.newDraft(name: "Tekst")
        studio.text = "# Een\n\nEerste tekst.\n\n# Twee\n\nTweede tekst.\n"
        let before = studio.text
        studio.selection = NSRange(location: (before as NSString).range(of: "Tweede").location, length: 0)
        FakeModel.answer = { _, _ in "# Twee\n\nBetere tekst." }
        studio.apply(.improve)
        try await waitUntilDone()
        XCTAssertEqual(studio.text, "# Een\n\nEerste tekst.\n\n# Twee\n\nBetere tekst.\n")
        XCTAssertEqual(FakeModel.requests.last?.host, "fast.model.test")
        studio.undo()
        XCTAssertEqual(studio.text, before)
    }

    func testOwnInstructionGoesToTheHeavyModelOnTheSelection() async throws {
        studio.newDraft(name: "Tekst")
        studio.text = "Een zin die blijft. Een zin die verandert."
        studio.selection = (studio.text as NSString).range(of: "Een zin die verandert.")
        FakeModel.answer = { _, _ in "Nieuw." }
        studio.apply(instruction: "Herschrijf")
        try await waitUntilDone()
        XCTAssertEqual(studio.text, "Een zin die blijft. Nieuw.")
        XCTAssertEqual(FakeModel.requests.last?.host, "heavy.model.test")
    }

    func testEmptyAnswerChangesNothing() async throws {
        studio.newDraft(name: "Tekst")
        studio.text = "# Een\n\nTekst.\n"
        FakeModel.answer = { _, _ in "" }
        studio.apply(.shorter)
        try await waitUntilDone()
        XCTAssertEqual(studio.text, "# Een\n\nTekst.\n")
        XCTAssertNotNil(studio.problem)
    }

    func testAnImageFromADraftStaysInsideTheProject() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("geheim-\(UUID().uuidString).png")
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        try png.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try png.write(to: folder.appendingPathComponent("eigen.png"))
        studio.newDraft(name: "Plaatjes")
        studio.text = "# Kop\n\n![](../\(outside.lastPathComponent))\n\n![](\(outside.path))\n\n![](eigen.png)\n"
        studio.deliver()
        let pkg = try DocxPackage(url: try XCTUnwrap(studio.report?.url))
        XCTAssertEqual(pkg.names.filter { $0.hasPrefix("word/media/") }.count, 1)
    }

    func testNewFileNeverOverwrites() throws {
        try Data().write(to: folder.appendingPathComponent("Rapport.docx"))
        XCTAssertEqual(DocumentStudio.unique(folder, "Rapport", "docx").lastPathComponent, "Rapport 2.docx")
        XCTAssertEqual(DocumentStudio.fileName("Wat/is: dit?"), "Wat is  dit")
    }
}

/// The two models, the sources and the search questions, without a model.
final class DocumentPartsTests: XCTestCase {
    private func model(_ id: String) throws -> ModelInfo { try XCTUnwrap(ModelCatalog.shared.model(id)) }

    private func plan(physical: UInt64, resident: UInt64, cache: UInt64 = 0) -> MemoryPlan {
        MemoryPlan(physical: physical, gpuLimit: physical, suggestedWiredLimitMB: 0, dense: resident, experts: 0, engram: 0, overhead: 0,
                   layers: 1, hostExpertLayers: [], gpuExperts: 0, cpuExperts: 0, expertCache: cache, tensorSplit: [], threads: 8, contextSize: 32_768, warnings: [])
    }

    func testFastModelOnlyWhenItFitsNextToTheHeavyOne() throws {
        let heavy = try model("qwen3.8-flash-next-q4"), small = try model("qwen3.6-35b-a3b-q4")
        let big: UInt64 = 128 << 30
        XCTAssertEqual(DocumentModels.fastModel(heavy: heavy, heavyPlan: plan(physical: big, resident: 95_000_000_000), downloaded: [heavy, small], physical: big)?.id, small.id)
        // 64 GB: the heavy model alone takes all of it
        let mid: UInt64 = 64 << 30
        XCTAssertNil(DocumentModels.fastModel(heavy: heavy, heavyPlan: plan(physical: mid, resident: 50_000_000_000), downloaded: [heavy, small], physical: mid))
        // streaming from the SSD: the free memory is for the experts
        XCTAssertNil(DocumentModels.fastModel(heavy: heavy, heavyPlan: plan(physical: big, resident: 30_000_000_000, cache: 40_000_000_000), downloaded: [heavy, small], physical: big))
        // not downloaded, or no smaller one
        XCTAssertNil(DocumentModels.fastModel(heavy: heavy, heavyPlan: plan(physical: big, resident: 95_000_000_000), downloaded: [heavy], physical: big))
        XCTAssertNil(DocumentModels.fastModel(heavy: small, heavyPlan: plan(physical: big, resident: 30_000_000_000), downloaded: [heavy, small], physical: big))
    }

    func testCitations() {
        let sources = [Citations.Source(title: "A", url: "https://a"), Citations.Source(title: "B", url: "https://b"), Citations.Source(title: "C [x]", url: "https://c")]
        let done = Citations.finish("Eerst [3], dan [1, 3] en [7]. Geen [link](https://x) of [tekst].", sources: sources, heading: "Bronnen", consulted: "vandaag")
        XCTAssertTrue(done.markdown.hasPrefix("Eerst [1], dan [2, 1] en. Geen [link](https://x) of [tekst]."), done.markdown)
        XCTAssertTrue(done.markdown.contains("1. [C [x)](https://c) (vandaag)\n2. [A](https://a) (vandaag)"), done.markdown)
        XCTAssertFalse(done.markdown.contains("https://b"))
        XCTAssertEqual(done.unknown, [7])
        XCTAssertEqual(done.cited, 2)
        // without references the list says what was consulted
        let none = Citations.finish("Tekst.", sources: sources, heading: "Bronnen", consulted: "vandaag")
        XCTAssertEqual(none.cited, 0)
        XCTAssertTrue(none.markdown.contains("https://b"))
    }

    func testSearchQuestionLosesPersonalData() {
        XCTAssertEqual(SearchQuery.clean("schade NL91ABNA0417164300 piet@voorbeeld.nl bsn 123456782"), "schade bsn")
        XCTAssertEqual(SearchQuery.clean("offerte € 12.500 van 06-12345678 dossier 2024001234"), "offerte van dossier")
        XCTAssertEqual(SearchQuery.clean("artikel 5.1 AVG 2024"), "artikel 5.1 AVG 2024")
    }

    func testSections() {
        let text = "---\nveld: x\n---\n\nVoorwoord\n\n# Een\n\nTekst\n\n```\n# geen kop\n```\n\n## Sub\n\nMeer\n\n# Twee\n"
        let list = DraftSections.list(text)
        XCTAssertEqual(list.map(\.title), ["Een", "Sub", "Twee"])
        XCTAssertTrue(list[0].hasChildren)
        XCTAssertFalse(list[1].hasChildren)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: DraftSections.scope(in: text, selection: NSRange(location: ns.range(of: "Meer").location, length: 0))), "## Sub\n\nMeer\n\n")
        XCTAssertEqual(ns.substring(with: DraftSections.scope(in: text, selection: NSRange(location: 0, length: 0))), "Voorwoord\n\n# Een\n\nTekst\n\n```\n# geen kop\n```\n\n## Sub\n\nMeer\n\n# Twee\n")
        XCTAssertEqual(DraftSections.cleaned("```markdown\n# Een\n\nTekst\n```", removingHeading: "Een"), "Tekst")
    }

    func testDraftFieldsSurviveEditing() {
        let d = DocumentDraft(fields: [(key: "Betreft", value: "A: B # C"), (key: "Klant", value: "")], body: "# Kop\n")
        let again = DocumentDraft(markdown: d.markdown)
        XCTAssertEqual(again.fields.map(\.value), ["A: B # C", ""])
        XCTAssertEqual(again.body, "# Kop\n")
        XCTAssertEqual(again.title, "A: B # C")
        XCTAssertEqual(DocumentDraft(markdown: "Geen velden\n---\nmeer").fields.count, 0)
    }
}
