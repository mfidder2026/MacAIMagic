import XCTest
import SwiftUI
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

    /// What a model that reads a requirements attachment answers when it plans.
    private static let plan = "TITEL: AQS Citrix\nOPBOUW: eisen.txt\n# Inleiding\n> Waarom deze scan.\n# Bevindingen\n> Per thema.\n## Beveiliging\n> MFA.\nZOEK: eisen BIO aan MFA\nZOEK: citrix beveiliging Gemeente Voorbeeld\n"
    private static let planWithoutSearch = "TITEL: AQS Citrix\nOPBOUW: eisen.txt\n# Inleiding\n> Waarom deze scan.\n# Bevindingen\n"

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
            return (url.contains("a.example") ? "Bron A" : "Bron B", "Inhoud van \(url): MFA is verplicht.")
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

    private func attach(_ name: String, _ text: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bron-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = dir.appendingPathComponent(name)
        try text.write(to: note, atomically: true, encoding: .utf8)
        studio.addAttachment(note)
    }

    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sjabloon.docx") }

    private func named(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: fixture, to: url)
        return url
    }

    /// A model that plans with `plan`, reads pages, and writes.
    private func answer(plan: String, section: String = "Tekst [1].") {
        FakeModel.answer = { system, user in
            if system.contains("hoe een document eruit moet zien") { return plan }
            if system.contains("webpagina") { return user.contains("appeltaart") ? "NIETS" : "MFA is verplicht." }
            if system.contains("voorblad") { return "" }
            return section
        }
    }

    // MARK: - the way of a document

    /// Ling wrote "veld: Klant: Gemeente Voorbeeld", so in 1.14.10 the cover stayed empty.
    func testTheCoverReadsWhatASmallModelWrites() {
        let answer = """
        veld: Klant: Gemeente Voorbeeld
        - **versie:** 0.2
        Aanleiding: Verouderde koppeling
        auteur: 'M. Fidder'
        Klant: Andere klant
        """
        let found = DocumentStudio.coverValues(answer, fields: ["Klant", "versie", "auteur"])
        XCTAssertEqual(found.map(\.key), ["Klant", "versie", "auteur"])
        XCTAssertEqual(found.map(\.value), ["Gemeente Voorbeeld", "0.2", "M. Fidder"])
        // "unknown" and the template's own marking are no value
        let none = DocumentStudio.coverValues("Klant: onbekend\nversie: (niet vermeld)\nauteur: [Auteur]\nproject: -", fields: ["Klant", "versie", "auteur", "project"])
        XCTAssertTrue(none.isEmpty, "\(none)")
    }

    func testTheAttachmentsDecideWhatTheDocumentConsistsOf() async throws {
        try attach("eisen.txt", "Een AQS bestaat uit een inleiding en bevindingen.")
        answer(plan: Self.plan)
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertNil(studio.problem)

        // the attachments reach the heavy model first, with the instruction
        let first = try XCTUnwrap(FakeModel.requests.first)
        XCTAssertEqual(first.host, "heavy.model.test")
        let prompt = (first.body["messages"] as? [[String: Any]])?.last?["content"] as? String ?? ""
        XCTAssertTrue(prompt.contains("Een AQS bestaat uit een inleiding en bevindingen."))
        XCTAssertTrue(prompt.contains("Maak een AQS"))

        XCTAssertEqual(DraftSections.list(studio.text).map(\.title), ["Inleiding", "Bevindingen", "Beveiliging", "Bronnen"])
        XCTAssertEqual(studio.selected?.lastPathComponent, "AQS Citrix.md")
        XCTAssertEqual(DocumentDraft(markdown: studio.text).title, "AQS Citrix")
        XCTAssertTrue(studio.steps.contains { $0.text.contains("eisen.txt") }, "the user sees where the structure came from")

        // a draft on disk, and no document yet: the house style comes last
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".docx") }, [])
    }

    func testWhatTheAttachmentsSayNeedsNoInternet() async throws {
        try attach("eisen.txt", "Alles staat hierin.")
        answer(plan: Self.planWithoutSearch, section: "Tekst.")
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertNil(studio.problem)
        XCTAssertEqual(searched, [])
        XCTAssertFalse(studio.text.contains("# Bronnen"))
    }

    func testInternetCanBeLeftOut() async throws {
        try attach("eisen.txt", "Iets.")
        answer(plan: Self.plan, section: "Tekst.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertEqual(searched, [])
        let system = (FakeModel.requests.first?.body["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        XCTAssertFalse(system.contains("ZOEK staat op een eigen regel"))
    }

    func testTheClientStaysOffTheSearchEngine() async throws {
        studio.project.fields = [.init(key: "Klant", value: "Gemeente Voorbeeld")]
        try attach("eisen.txt", "Iets.")
        answer(plan: Self.plan)
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertEqual(searched.first, "eisen BIO aan MFA")
        XCTAssertFalse(searched.joined(separator: " ").lowercased().contains("gemeente voorbeeld"), "\(searched)")
    }

    func testFastModelReadsPagesAndHeavyModelPlansAndWrites() async throws {
        answer(plan: Self.plan)
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        let hosts = FakeModel.requests.map(\.host)
        XCTAssertEqual(hosts.first, "heavy.model.test")
        XCTAssertTrue(hosts.contains("fast.model.test"))
        // text from the web reaches a model without tools, so a page cannot make it do anything
        XCTAssertTrue(FakeModel.requests.allSatisfy { $0.body["tools"] == nil })
    }

    func testSourcesAreCheckedAndNumberedByTheApp() async throws {
        answer(plan: Self.planWithoutSearch + "ZOEK: mfa eisen\n", section: "MFA is verplicht [2]. Ook [1, 2]. Verzonnen [9]. Volgens bron 2 veel.")
        studio.make(request: "Hoe zit het met MFA?", useWeb: true)
        try await waitUntilDone()
        XCTAssertNil(studio.problem)
        let body = DocumentDraft(markdown: studio.text).body
        // in the order the text uses them: B first, the made-up one gone
        XCTAssertTrue(body.contains("verplicht [1]."), body)
        XCTAssertTrue(body.contains("[2, 1]"), body)
        XCTAssertFalse(body.contains("[9]"))
        XCTAssertTrue(body.contains("1. [Bron B](https://b.example/2)"), body)
        XCTAssertTrue(body.contains("2. [Bron A](https://a.example/1)"), body)
        XCTAssertFalse(body.contains("ruis.example"))
        XCTAssertTrue(studio.notes.contains { $0.contains("[9]") })
        XCTAssertTrue(studio.notes.contains { $0.contains("'bron 3'") })
        XCTAssertTrue(studio.notes.contains { $0.contains("2 pagina's") })
    }

    func testTheListOfSourcesIsNoReasonForAWarning() async throws {
        answer(plan: Self.planWithoutSearch + "ZOEK: mfa\n", section: "Een feit [1].")
        studio.make(request: "Hoe snel", useWeb: true)
        try await waitUntilDone()
        XCTAssertEqual(studio.notes.filter { $0.contains("'bron 3'") }, [])
    }

    func testAPageIsJudgedAgainstTheQuestionThatFoundIt() async throws {
        var asked: [String] = []
        FakeModel.answer = { system, user in
            if system.contains("hoe een document eruit moet zien") { return Self.plan }
            if system.contains("webpagina") {
                asked.append(user)
                return "MFA is verplicht."
            }
            return "Tekst [1]."
        }
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertFalse(asked.isEmpty)
        XCTAssertTrue(asked.allSatisfy { $0.contains("Vraag: eisen BIO aan MFA") || $0.contains("Vraag: citrix beveiliging") }, "\(asked.first ?? "")")
        XCTAssertFalse(asked.contains { $0.contains("Maak een AQS") })
    }

    func testEveryQuestionGetsItsTurn() async throws {
        var read: [String] = []
        studio.searchWeb = { q in (1...20).map { WebTools.Hit(title: "\(q) \($0)", url: "https://x.example/\(q.hashValue)/\($0)", snippet: "") } }
        studio.fetchPage = { url in
            read.append(url)
            return ("Pagina", "Inhoud.")
        }
        answer(plan: Self.planWithoutSearch + "ZOEK: een\nZOEK: twee\nZOEK: drie\n", section: "Tekst [1].")
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertEqual(read.count, DocumentStudio.maxPages)
        XCTAssertEqual(Set(read.map { URL(string: $0)!.pathComponents[1] }).count, 3, "not all pages from the first question")
    }

    func testNothingFoundWithoutAttachmentsWritesNothing() async throws {
        answer(plan: Self.plan)
        studio.searchWeb = { _ in [] }
        studio.make(request: "Iets onvindbaars", useWeb: true)
        try await waitUntilDone()
        XCTAssertNotNil(studio.problem)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".md") }, [])
    }

    func testTheTextOnlyChangesOnTheMainThread() async throws {
        var offMain = 0, changes = 0
        let watch = studio.objectWillChange.sink {
            changes += 1
            if !Thread.isMainThread { offMain += 1 }
        }
        defer { watch.cancel() }
        answer(plan: Self.plan)
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertGreaterThan(changes, 5)
        XCTAssertEqual(offMain, 0, "a screen changed from another thread locked up the whole app in 1.9.3")
    }

    func testTheScreenKeepsWorkingWhileTheModelWrites() async throws {
        let app = AppState()
        let project = app.documents
        project.choose(folder: folder)
        project.endpoint = { role in (URL(string: "http://heavy.model.test")!, "zwaar") }
        project.searchWeb = { _ in [] }
        let chunk = String(repeating: "Een zin met woorden. ", count: 400)
        FakeModel.answer = { system, _ in system.contains("hoe een document eruit moet zien") ? Self.plan : chunk }
        let root = DocumentsView()
            .environmentObject(app).environmentObject(app.engine).environmentObject(app.models).environmentObject(app.store)
            .environmentObject(app.chat).environmentObject(Settings.shared).environmentObject(app.metrics).environmentObject(app.bench)
            .environmentObject(app.cluster).environmentObject(app.check).environmentObject(project)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        project.page = .newDocument
        project.make(request: "Maak een AQS", useWeb: false)
        let start = Date()
        var ticks = 0
        while project.busy && Date().timeIntervalSince(start) < 30 {
            window.contentView?.layoutSubtreeIfNeeded()
            ticks += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(project.busy)
        XCTAssertGreaterThan(ticks, 1)
        XCTAssertTrue(project.text.contains("Een zin met woorden."))
        project.choose(folder: FileManager.default.temporaryDirectory)
        Settings.shared.documentFolder = ""
    }

    func testNothingFoundWithAttachmentsStillWritesAndSaysSo() async throws {
        try attach("eisen.txt", "Iets.")
        answer(plan: Self.plan, section: "Tekst.")
        studio.searchWeb = { _ in [] }
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertNil(studio.problem)
        XCTAssertFalse(DraftSections.list(studio.text).isEmpty)
        XCTAssertTrue(studio.notes.contains { $0.contains("niets gevonden") }, "\(studio.notes)")
    }

    func testWithoutAttachmentsOrSourcesTheUserIsWarned() async throws {
        answer(plan: Self.planWithoutSearch, section: "Tekst.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertTrue(studio.notes.contains { $0.contains("zonder bijlagen") })
    }

    func testAnEngineThatFailsIsNotCalledAnUnreadablePage() async throws {
        answer(plan: Self.plan)
        var calls = 0
        studio.endpoint = { _ in
            calls += 1
            if calls > 1 { return (URL(string: "http://127.0.0.1:1")!, "weg") }
            return (URL(string: "http://heavy.model.test")!, "zwaar")
        }
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: true)
        try await waitUntilDone()
        XCTAssertNotNil(studio.problem)
    }

    func testAModelThatKeepsToNoFormGetsTheHouseStylesHeadings() async throws {
        studio.useHouseStyle(fixture)
        FakeModel.answer = { system, _ in system.contains("hoe een document eruit moet zien") ? "Dat weet ik niet." : "Tekst." }
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertNil(studio.problem)
        XCTAssertTrue(DraftSections.list(studio.text).map(\.title).contains("Inleiding"))
    }

    func testThinkingOffIsAlsoAskedOfTemplatesThatIgnoreIt() async throws {
        answer(plan: Self.planWithoutSearch, section: "Tekst.")
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        let writing = FakeModel.requests.dropFirst()
        XCTAssertFalse(writing.isEmpty)
        for r in writing {
            XCTAssertEqual(r.body["thinking_budget_tokens"] as? Int, 0, "GLM always opens with <think>")
            XCTAssertEqual((r.body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        }
        XCTAssertGreaterThan(FakeModel.requests.first?.body["max_tokens"] as? Int ?? 0, 6000, "a long structure must fit, next to the thinking")
    }

    func testOneSilentSectionDoesNotStopTheOthers() async throws {
        var calls: [String: Int] = [:]
        FakeModel.answer = { system, user in
            if system.contains("hoe een document eruit moet zien") { return Self.plan }
            if system.contains("voorblad") { return "" }
            if user.contains("sectie 'Bevindingen'") {
                calls["Bevindingen", default: 0] += 1
                return ""
            }
            return "Tekst."
        }
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertNil(studio.problem)
        XCTAssertEqual(calls["Bevindingen"], 2, "once more before giving up")
        XCTAssertTrue(studio.notes.contains { $0.contains("Bevindingen") }, "\(studio.notes)")
        XCTAssertTrue(studio.text.contains("Per thema."), "its instruction stays")
        let sections = DraftSections.list(studio.text)
        XCTAssertEqual(sections.map(\.title), ["Inleiding", "Bevindingen", "Beveiliging"])
        XCTAssertTrue((studio.text as NSString).substring(with: sections[2].range).contains("Tekst."), "the section after it is written")
    }

    func testASilentRetryCanStillAnswer() async throws {
        var calls = 0
        FakeModel.answer = { system, user in
            if system.contains("hoe een document eruit moet zien") { return Self.planWithoutSearch }
            if system.contains("voorblad") { return "" }
            calls += 1
            return calls == 1 ? "" : "Tweede poging."
        }
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertTrue(studio.text.contains("Tweede poging."))
        XCTAssertEqual(studio.notes, [])
    }

    func testARepeatingSectionIsCutAndSaidSo() async throws {
        let loop = LoopGuardTests.loop
        FakeModel.answer = { system, user in
            if system.contains("hoe een document eruit moet zien") { return Self.planWithoutSearch }
            if system.contains("voorblad") { return "" }
            return "Begin van de tekst.\n" + loop + loop + loop + loop + loop
        }
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertTrue(studio.notes.contains { $0.contains("herhaalde zichzelf") }, "\(studio.notes)")
        XCTAssertFalse(studio.notes.contains { $0.contains("te lang werd") })
        let first = DraftSections.list(studio.text)[0]
        let body = (studio.text as NSString).substring(with: first.range)
        XCTAssertEqual(body.components(separatedBy: "niet in aanmerking komt").count - 1, 1, "one copy of the line stays")
        // every piece of writing asks for the DRY sampler
        let writing = FakeModel.requests.filter { $0.body["max_tokens"] != nil }
        XCTAssertFalse(writing.isEmpty)
        XCTAssertTrue(writing.allSatisfy { ($0.body["dry_multiplier"] as? Double) == 0.8 })
    }

    /// WinAIMagic's AProjectCanBeRemoved: to the Trash (a stand-in) or only off the list; the next project opens.
    func testAProjectCanBeRemoved() throws {
        let saved = (Settings.shared.documentProjects, Settings.shared.documentFolder)
        defer { Settings.shared.documentProjects = saved.0; Settings.shared.documentFolder = saved.1 }
        // only this test's two projects, whatever an earlier run left in the list (read when a studio is made)
        Settings.shared.documentProjects = ""
        let studio = DocumentStudio(folder: folder)
        let other = folder.deletingLastPathComponent().appendingPathComponent("macaimagic-docs-ander-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        studio.choose(folder: other)
        studio.choose(folder: folder)
        var trashed: [URL] = []
        studio.trashItem = { trashed.append($0) }

        studio.removeProject(trash: false)
        XCTAssertEqual(trashed, [], "only off the list: the folder stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(studio.projects.contains { $0.standardizedFileURL == folder.standardizedFileURL })
        XCTAssertEqual(studio.folder.standardizedFileURL, other.standardizedFileURL, "the other project opens")

        studio.removeProject(trash: true)
        XCTAssertEqual(trashed.map(\.standardizedFileURL), [other.standardizedFileURL])
        XCTAssertFalse(studio.projects.contains { $0.standardizedFileURL == other.standardizedFileURL })
    }

    func testWritingKeepsThePlannedSections() async throws {
        FakeModel.answer = { system, user in
            if system.contains("hoe een document eruit moet zien") { return Self.plan }
            if system.contains("voorblad") { return "" }
            // a model that adds a heading must not shift the sections
            return "### Extra kop\n\nTekst voor de sectie."
        }
        try attach("eisen.txt", "Iets.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertEqual(DraftSections.list(studio.text).map(\.title), ["Inleiding", "Bevindingen", "Beveiliging"])
        XCTAssertFalse(studio.text.contains("<!-- "), "instructions are replaced by text")
        XCTAssertTrue(studio.text.contains("**Extra kop**"))
        XCTAssertTrue(FakeModel.requests.contains { (($0.body["messages"] as? [[String: Any]])?.last?["content"] as? String)?.contains("Per thema.") == true }, "each section gets its instruction")
    }

    // MARK: - the house style

    func testHouseStyleKeepsItsOwnName() throws {
        studio.useHouseStyle(try named("aqs template.docx"))
        XCTAssertEqual(studio.houseStyle?.lastPathComponent, "aqs template.docx")
        XCTAssertEqual(DocumentStudio(folder: folder).houseStyle?.lastPathComponent, "aqs template.docx")

        let bad = folder.appendingPathComponent("geen-word.docx")
        try Data("geen zip".utf8).write(to: bad)
        studio.useHouseStyle(bad)
        XCTAssertNotNil(studio.problem)
        XCTAssertEqual(studio.houseStyle?.lastPathComponent, "aqs template.docx", "a bad file does not replace the house style")

        studio.useHouseStyle(try named("andere.docx"))
        XCTAssertEqual(studio.houseStyle?.lastPathComponent, "andere.docx", "a project has one house style")
    }

    func testTheOldHouseStyleFileStillCounts() throws {
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("huisstijl.docx"))
        studio.refresh()
        XCTAssertEqual(studio.houseStyle?.lastPathComponent, "huisstijl.docx")
    }

    func testTheLayoutComesLastAndNotItsText() async throws {
        studio.useHouseStyle(fixture)
        try attach("eisen.txt", "Iets.")
        answer(plan: Self.planWithoutSearch, section: "Onze eigen tekst.")
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        studio.deliver()
        XCTAssertEqual(studio.report?.problems, [])
        let model = DocModel(try DocxPackage(url: try XCTUnwrap(studio.report?.url)))
        XCTAssertEqual(model.outline().map(\.title), ["Inleiding", "Bevindingen"], "the structure of the draft, not of the house style")
        let text = model.blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("Onze eigen tekst."))
        XCTAssertFalse(text.contains("Voorbeeldknelpunt"), "the house style's example text is gone")
        XCTAssertTrue(text.contains("Architecture Quick Scan"), "its cover stays")
    }

    func testDeliverKeepsTheOldDocument() throws {
        studio.newDocument(name: "Rapport")
        studio.deliver()
        let first = try XCTUnwrap(studio.report?.url)
        studio.deliver()
        XCTAssertNotEqual(studio.report?.url, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    // MARK: - the project

    func testWhatTheProjectKnowsIsEnteredOnce() async throws {
        studio.useHouseStyle(fixture)
        XCTAssertTrue(Set(studio.project.fields.map { DocxFields.normalized($0.key) }).isSuperset(of: ["klant", "versie"]), "the cover's fields become the project's")
        let i = try XCTUnwrap(studio.project.fields.firstIndex { DocxFields.normalized($0.key) == "klant" })
        studio.project.fields[i].value = "RIVM"
        try attach("eisen.txt", "Versie 0.2 van de scan.")

        var prompts: [String] = []
        FakeModel.answer = { system, user in
            prompts.append(user)
            if system.contains("hoe een document eruit moet zien") { return Self.planWithoutSearch }
            if system.contains("voorblad") { return "versie: 0.2" }
            return "Tekst."
        }
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertNil(studio.problem)
        XCTAssertTrue(prompts.contains { $0.contains("Klant: RIVM") || $0.contains("klant: RIVM") })
        func field(_ key: String) -> String? { DocumentDraft(markdown: studio.text).fields.first { DocxFields.normalized($0.key) == key }?.value }
        XCTAssertEqual(field("klant"), "RIVM")
        XCTAssertEqual(field("versie"), "0.2")
        XCTAssertFalse(field("datum")?.isEmpty ?? true, "today's date needs nobody")

        // what was found out is known for the next document, without a model
        studio.newDocument(name: "Tweede")
        XCTAssertEqual(field("klant"), "RIVM")
        XCTAssertEqual(field("versie"), "0.2")

        // and it is all still there when the project is opened again
        let again = DocumentStudio(folder: folder)
        XCTAssertEqual(again.project.value("klant"), "RIVM")
        XCTAssertEqual(again.houseStyle?.lastPathComponent, "sjabloon.docx")
        XCTAssertEqual(again.attachments.map(\.lastPathComponent), ["eisen.txt"])
        XCTAssertEqual(Set(again.drafts.map(\.lastPathComponent)), ["AQS Citrix.md", "Tweede.md"])
    }

    func testExampleValuesOfTheHouseStyleStayOut() {
        studio.useHouseStyle(fixture)
        studio.newDocument(name: "Een")
        let fields = DocumentDraft(markdown: studio.text).fields
        XCTAssertEqual(fields.first { $0.key == "titel" }?.value, "Een")
        XCTAssertEqual(fields.first { DocxFields.normalized($0.key) == "klant" }?.value, "", "[Klantnaam] is no value")
    }

    func testProjectsAreKept() throws {
        let saved = (Settings.shared.documentProjects, Settings.shared.documentFolder)
        defer { (Settings.shared.documentProjects, Settings.shared.documentFolder) = saved }
        Settings.shared.documentProjects = ""
        let root = folder.appendingPathComponent("wortel", isDirectory: true)
        let s = DocumentStudio(folder: folder, root: root)
        s.createProject(name: "Citrix SPA")
        s.createProject(name: "Citrix SPA")
        XCTAssertEqual(s.folder.lastPathComponent, "Citrix SPA 2", "an existing project is never taken over")
        s.project.fields = [.init(key: "Klant", value: "Tweede")]
        s.choose(folder: root.appendingPathComponent("Citrix SPA"))
        XCTAssertEqual(s.project.fields, [], "each project its own")
        XCTAssertEqual(DocumentStudio(root: root).projects.map(\.lastPathComponent).filter { $0.hasPrefix("Citrix") }, ["Citrix SPA", "Citrix SPA 2"])
    }

    func testAttachmentWithoutTextIsRefused() throws {
        try attach("leeg.txt", "   ")
        XCTAssertNotNil(studio.problem)
        XCTAssertEqual(studio.attachments, [])
    }

    func testAWordAttachmentIsReadWhole() async throws {
        studio.addAttachment(fixture)
        var plan = ""
        FakeModel.answer = { system, user in
            if system.contains("hoe een document eruit moet zien") { plan = user; return Self.planWithoutSearch }
            return "Tekst."
        }
        studio.make(request: "Maak een AQS", useWeb: false)
        try await waitUntilDone()
        XCTAssertTrue(plan.contains("Architecture Quick Scan"), "also what stands before the first heading")
        XCTAssertTrue(plan.contains("Beschrijf de aanleiding"), "and the instructions")
    }

    // MARK: - changing a draft

    func testActionWorksOnTheSectionAtTheCursorAndCanBeUndone() async throws {
        studio.newDocument(name: "Tekst")
        studio.text = "# Een\n\nEerste tekst.\n\n# Twee\n\nTweede tekst.\n"
        let before = studio.text
        studio.selection = NSRange(location: (before as NSString).range(of: "Tweede").location, length: 0)
        XCTAssertEqual(studio.scopeTitle, "sectie 'Twee'")
        FakeModel.answer = { _, _ in "# Twee\n\nBetere tekst." }
        studio.apply(.improve)
        try await waitUntilDone()
        XCTAssertEqual(studio.text, "# Een\n\nEerste tekst.\n\n# Twee\n\nBetere tekst.\n")
        XCTAssertEqual(FakeModel.requests.last?.host, "fast.model.test")
        studio.undo()
        XCTAssertEqual(studio.text, before)
    }

    func testOwnInstructionGoesToTheHeavyModelOnTheSelection() async throws {
        studio.newDocument(name: "Tekst")
        studio.text = "Een zin die blijft. Een zin die verandert."
        studio.selection = (studio.text as NSString).range(of: "Een zin die verandert.")
        XCTAssertEqual(studio.scopeTitle, "de selectie")
        FakeModel.answer = { _, _ in "Nieuw." }
        studio.apply(instruction: "Herschrijf")
        try await waitUntilDone()
        XCTAssertEqual(studio.text, "Een zin die blijft. Nieuw.")
        XCTAssertEqual(FakeModel.requests.last?.host, "heavy.model.test")
    }

    func testEmptyAnswerChangesNothing() async throws {
        studio.newDocument(name: "Tekst")
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
        studio.newDocument(name: "Plaatjes")
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

/// Which search engine is asked, without the internet.
final class SearchRouteTests: XCTestCase {
    private actor Log {
        var calls: [String] = []
        func add(_ s: String) { calls.append(s) }
    }

    private func hit(_ s: String) -> [WebTools.Hit] { [WebTools.Hit(title: s, url: "https://\(s)", snippet: "")] }

    func testARefusalGoesToTheOtherEngineAndStaysThereForAWhile() async throws {
        let route = SearchRoute(spacing: 0, pause: 600), log = Log()
        let primary: @Sendable (String) async throws -> [WebTools.Hit] = { _ in
            await log.add("duck")
            throw WebTools.Blocked()
        }
        let hits = [WebTools.Hit(title: "bing", url: "https://bing", snippet: "")]
        let fallback: @Sendable (String) async throws -> [WebTools.Hit] = { _ in
            await log.add("bing")
            return hits
        }
        let first = try await route.search("a", primary: primary, fallback: fallback)
        let second = try await route.search("b", primary: primary, fallback: fallback)
        XCTAssertEqual(first.first?.title, "bing")
        XCTAssertEqual(second.first?.title, "bing")
        let calls = await log.calls
        XCTAssertEqual(calls, ["duck", "bing", "bing"], "refused engines are left alone")
    }

    func testAnEmptyAnswerAsksTheOtherEngineToo() async throws {
        let route = SearchRoute(spacing: 0)
        let hits = hit("bing")
        let found = try await route.search("a", primary: { _ in [] }, fallback: { _ in hits })
        XCTAssertEqual(found.first?.title, "bing")
    }

    func testAGoodAnswerIsEnough() async throws {
        let route = SearchRoute(spacing: 0), log = Log()
        let hits = hit("duck")
        _ = try await route.search("a", primary: { _ in hits }, fallback: { _ in
            await log.add("bing")
            return []
        })
        let calls = await log.calls
        XCTAssertEqual(calls, [])
    }

    func testSearchesAreSpacedOut() async throws {
        let route = SearchRoute(spacing: 0.3)
        let hits = hit("duck")
        let t = Date()
        _ = try await route.search("a", primary: { _ in hits }, fallback: { _ in [] })
        _ = try await route.search("b", primary: { _ in hits }, fallback: { _ in [] })
        XCTAssertGreaterThan(Date().timeIntervalSince(t), 0.25)
    }

    func testBlockPageIsRecognized() {
        XCTAssertTrue(WebTools.isBlocked(status: 202, html: ""))
        XCTAssertTrue(WebTools.isBlocked(status: 200, html: "<div class=\"anomaly-modal__title\">"))
        XCTAssertFalse(WebTools.isBlocked(status: 200, html: "<a class=\"result__a\">"))
    }

    func testBingResults() {
        let target = Data("https://www.example.org/pagina?a=1".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let html = "<ol><li class=\"b_algo\" data-x=\"1\"><div>k</div><h2 class=\"t\"><a target=\"_blank\" href=\"https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;u=a1\(target)&amp;ntb=1\" h=\"ID\">Een <strong>titel</strong></a></h2><p>x</p></li><li class=\"b_algo\"><h2><a href=\"https://direct.example/b\">Direct</a></h2></li><li class=\"b_ad\"><h2><a href=\"https://reclame.example\">Reclame</a></h2></li></ol>"
        let hits = WebTools.parseBing(html)
        XCTAssertEqual(hits.map(\.url), ["https://www.example.org/pagina?a=1", "https://direct.example/b"])
        XCTAssertEqual(hits.first?.title, "Een titel")
        XCTAssertNil(WebTools.bingTarget("https://www.bing.com/ck/a?u=zonder"))
    }
}

/// Engines left behind by a forced quit.
final class EngineOrphanTests: XCTestCase {
    func testOnlyEnginesWithoutAnAppAreStopped() {
        let list = """
          100     1 /Users/x/RELEASE/MacAIMagic.app/Contents/Resources/engine/llama-server --model a --port 8080
          200   376 /Users/x/RELEASE/MacAIMagic.app/Contents/Resources/engine/llama-server --model b --port 8081
          300     1 /Users/x/engine/bin/llama-server --model c
          400     1 /usr/sbin/cfprefsd
        """
        XCTAssertEqual(EngineOrphans.pids(inProcessList: list), [100])
    }
}

/// The two models, the plan, the sources and the search questions, without a model.
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

    func testPlanFromAModelsAnswer() {
        let plan = DocumentPlan(answer: "```\nTITEL: AQS Citrix\nOpbouw: eisen.docx\nHier is de opbouw:\n# **Inleiding**\n> Waarom.\n> En hoe.\n## Scope\nZOEK: eisen BIO\nzoek: - MFA regels\n```", fallbackTitle: "Maak iets")
        XCTAssertEqual(plan.title, "AQS Citrix")
        XCTAssertEqual(plan.origin, "eisen.docx")
        XCTAssertEqual(plan.sections, [.init(level: 1, title: "Inleiding", instruction: "Waarom. En hoe."), .init(level: 2, title: "Scope", instruction: "")])
        XCTAssertEqual(plan.searches, ["eisen BIO", "MFA regels"])
        XCTAssertTrue(plan.outline.contains("# Inleiding\n\n<!-- instructie: Waarom. En hoe. -->"), plan.outline)
        XCTAssertEqual(DocumentPlan(answer: "onzin", fallbackTitle: "Maak iets").title, "Maak iets")
        XCTAssertEqual(DocumentPlan(answer: (1...9).map { "ZOEK: q\($0)" }.joined(separator: "\n"), fallbackTitle: "x").searches.count, 5)
    }

    func testTheTopHeadingIsTheTitleNotAChapter() {
        let plan = DocumentPlan(answer: "OPBOUW: t.md\n# Architectuur Quick Scan\n## 1 Inleiding\n> Doel.\n### 1.1 Scope\n## 2 Advies\n### 4.2\n", fallbackTitle: "Maak een AQS")
        XCTAssertEqual(plan.title, "Architectuur Quick Scan")
        XCTAssertEqual(plan.sections.map(\.title), ["1 Inleiding", "1.1 Scope", "2 Advies"], "a heading of only a number is no heading")
        XCTAssertEqual(plan.sections.map(\.level), [1, 2, 1])
        // several chapters at the top stay chapters
        XCTAssertEqual(DocumentPlan(answer: "# Een\n## Sub\n# Twee\n", fallbackTitle: "x").sections.map(\.title), ["Een", "Sub", "Twee"])
        // with an instruction and a few chapters below it, it is the title too
        XCTAssertEqual(DocumentPlan(answer: "TITEL: T\n# Titel\n> Uitleg.\n## A\n## B\n## C\n", fallbackTitle: "x").sections.map(\.title), ["A", "B", "C"])
        // one section stays a section
        XCTAssertEqual(DocumentPlan(answer: "# Samenvatting\n", fallbackTitle: "x").sections.map(\.title), ["Samenvatting"])
        XCTAssertEqual(DocumentPlan(answer: "TITEL: T\n# Een\n# Twee\n# Half", fallbackTitle: "x", cutOff: true).sections.map(\.title), ["Een", "Twee"])
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
        XCTAssertEqual(SearchQuery.clean("eisen voor gemeente voorbeeld over MFA", sensitive: ["Gemeente Voorbeeld"]), "eisen voor over MFA")
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

/// The name at the top of the sidebar stays clear of the window's buttons.
@MainActor
final class WindowLayoutTests: XCTestCase {
    func testTheSidebarLeavesRoomForTheWindowButtons() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "test")
        window.toolbarStyle = .unified
        window.layoutIfNeeded()
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let rect = button.convert(button.bounds, to: nil)
            XCTAssertLessThan(window.frame.height - rect.minY, Sidebar.windowButtonsHeight, "\(kind)")
        }
    }
}

/// When the fast model does not start, the work goes on and the user can see why.
@MainActor
final class FastModelTests: XCTestCase {
    private var app: AppState!
    private var engines: DocumentEngines!
    private var launches = 0
    private var failure: Error?

    override func setUp() async throws {
        app = AppState()
        engines = DocumentEngines(app: app)
        let small = try XCTUnwrap(ModelCatalog.shared.model("qwen3.6-35b-a3b-q4"))
        engines.choose = { small }
        engines.launch = { [unowned self] _ in
            launches += 1
            if let failure { throw failure }
        }
        // never the real one: a test must not load a model next to the user's
        engines.heavyEngine = { (URL(string: "http://heavy.model.test")!, "zwaar") }
    }

    private func fastEndpoint() async -> String? { try? await engines.endpoint(.fast).model }

    func testAFailureIsKeptAndNotTriedForEveryPage() async {
        failure = Zip.Failure("poort bezet")
        _ = await fastEndpoint()
        _ = await fastEndpoint()
        _ = await fastEndpoint()
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(engines.fastProblem, "poort bezet")
    }

    func testTheButtonTriesAgainAndClearsTheProblem() async throws {
        failure = Zip.Failure("poort bezet")
        _ = await fastEndpoint()
        failure = nil
        engines.startFastNow()
        XCTAssertNil(engines.fastProblem)
        for _ in 0..<100 where launches < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(launches, 2)
        XCTAssertNil(engines.fastProblem)
        let model = await fastEndpoint()
        XCTAssertEqual(model, "qwen3.6-35b-a3b-q4")
    }

    func testAWorkingModelIsUsed() async {
        let model = await fastEndpoint()
        XCTAssertEqual(model, "qwen3.6-35b-a3b-q4")
        XCTAssertNil(engines.fastProblem)
    }

    func testAFailureFallsBackToTheHeavyModel() async {
        failure = Zip.Failure("poort bezet")
        let model = await fastEndpoint()
        XCTAssertEqual(model, "zwaar")
    }

    func testAnotherChoiceIsTriedAfterAFailure() async throws {
        failure = Zip.Failure("poort bezet")
        _ = await fastEndpoint()
        let other = try XCTUnwrap(ModelCatalog.shared.model("glm-5.3-flash-compact"))
        engines.choose = { other }
        _ = await fastEndpoint()
        XCTAssertEqual(launches, 2)
    }

    func testStoppingTheWorkIsNoFailureOfTheModel() async {
        failure = CancellationError()
        _ = await fastEndpoint()
        XCTAssertNil(engines.fastProblem)
        _ = await fastEndpoint()
        XCTAssertEqual(launches, 2)
    }

    func testStoppingItYourselfIsNoFailure() async {
        engines.launch = { [unowned self] _ in
            engines.stopFast()
            throw Zip.Failure("De engine is gestopt.")
        }
        _ = await fastEndpoint()
        XCTAssertNil(engines.fastProblem)
    }

    func testAPortInUseIsSaidInPlainWords() {
        Settings.shared.language = "nl"
        XCTAssertEqual(DocumentEngines.readable("Engine gestopt (code 1): 0.00.048 E srv exiting due to HTTP server error", port: 8081), "Poort 8081 is al in gebruik door een ander programma.")
        XCTAssertEqual(DocumentEngines.readable("Geen geheugen", port: 8081), "Geen geheugen")
    }

    func testStatusSaysWhatTheModelIsDoing() {
        XCTAssertEqual(EngineController.State.stopped.statusText(idle: "vanzelf"), "vanzelf")
        XCTAssertEqual(EngineController.State.starting("Laden").statusText(idle: "x"), "Laden")
        XCTAssertEqual(EngineController.State.failed("kapot").statusText(idle: "x"), "kapot")
    }

    /// The real engine: a port in use, then free. MACAIMAGIC_FAST_TEST=1.
    func testRealEngineFailsVisiblyAndThenStarts() async throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_FAST_TEST"] == "1" else { throw XCTSkip("no real engine") }
        let saved = Settings.shared.port
        defer { Settings.shared.port = saved }
        Settings.shared.port = 8094     // the fast engine takes the next one
        let app = AppState()
        app.selectedModelID = "qwen3.8-flash-next-q4"
        let real = DocumentEngines(app: app)
        real.heavyEngine = { (URL(string: "http://heavy.model.test")!, "zwaar") }
        // the smallest downloaded model that fits beside it: which one depends on what this Mac has (Ling-3.0-tiny since 1.14.5)
        let choice = try XCTUnwrap(real.fastChoice, "a smaller downloaded model fits beside the heavy one")
        XCTAssertNotEqual(choice.id, app.selectedModelID)
        print("FAST choice:", choice.id)

        // whatever goes wrong below: no engine stays behind next to the user's
        defer { real.stopFast() }
        let blocker = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(8095).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(blocker, 1), 0)
        let t = Date()
        _ = try? await real.endpoint(.fast)
        print("FAST blocked after \(Int(Date().timeIntervalSince(t))) s:", real.fastProblem ?? "no problem", "| state", real.fast.state)
        XCTAssertNotNil(real.fastProblem)
        Darwin.close(blocker)
        // loading it takes the memory next to the user's model: only when asked
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_FAST_LOAD"] == "1" else { return }

        real.startFastNow()
        XCTAssertNil(real.fastProblem)
        let t0 = Date()
        while !real.fast.state.isRunning && real.fastProblem == nil && Date().timeIntervalSince(t0) < 240 { try await Task.sleep(for: .milliseconds(500)) }
        print("FAST started in \(Int(Date().timeIntervalSince(t0))) s:", real.fast.state, real.fastProblem ?? "")
        XCTAssertTrue(real.fast.state.isRunning)
        let answer = try await LocalModel.complete(url: real.fast.baseURL, model: "m", system: "Antwoord kort.", user: "Zeg alleen: klaar", maxTokens: 20)
        print("FAST answer:", answer.text, answer.tokensPerSecond ?? 0)
        real.stopFast()
        for _ in 0..<60 where real.fast.state != .stopped { try await Task.sleep(for: .milliseconds(500)) }
        XCTAssertEqual(real.fast.state, .stopped)
        XCTAssertNil(real.fastProblem)
    }
}

