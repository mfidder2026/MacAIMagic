import XCTest
import AppKit
import SwiftUI
@testable import MacAIMagic

/// However much the work has to report, the window stays within a laptop's screen and the buttons stay reachable.
@MainActor
final class DocumentLayoutTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("macaimagic-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        URLProtocol.registerClass(FakeModel.self)
        FakeModel.requests = []
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(FakeModel.self)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The app's own window content: the sidebar, the module, and the minimum size of the app.
    private func window(_ app: AppState) -> NSWindow {
        let root = NavigationSplitView {
            Sidebar(pane: .constant(.documents)).navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            DocumentsView()
        }
        .environmentObject(app).environmentObject(app.engine).environmentObject(app.models).environmentObject(app.store)
        .environmentObject(app.chat).environmentObject(Settings.shared).environmentObject(app.metrics).environmentObject(app.bench)
        .environmentObject(app.cluster).environmentObject(app.check).environmentObject(app.documents)
        .frame(minWidth: 1000, minHeight: 680)
        let controller = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        return w
    }

    /// A busy document: long steps, many remarks, a long section title.
    private func busyDraft(_ app: AppState) async throws {
        let s = app.documents
        s.choose(folder: folder)
        s.endpoint = { _ in (URL(string: "http://heavy.model.test")!, "zwaar") }
        let long = String(repeating: "zoekvraag met heel veel woorden ", count: 12)
        s.searchWeb = { _ in [WebTools.Hit(title: long, url: "https://a.example/1", snippet: "")] }
        s.fetchPage = { _ in throw URLError(.cannotFindHost) }
        // every section silent: a remark for each, under a long title
        let title = String(repeating: "Heel lange titel van een sectie ", count: 6)
        let plan = "TITEL: Rapport\nOPBOUW: x\n" + (1...25).map { "# \(title) \($0)\n" }.joined() + "ZOEK: \(long)\n"
        FakeModel.answer = { system, _ in system.contains("hoe een document eruit moet zien") ? plan : "" }
        try "Iets om te lezen.".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        s.addAttachment(folder.appendingPathComponent("b.txt"))
        s.make(request: "Maak iets", useWeb: true)
        let t = Date()
        while s.busy && Date().timeIntervalSince(t) < 20 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(s.busy)
        XCTAssertFalse(s.notes.isEmpty)
    }

    func testTheWindowDoesNotGrowOutOfALaptopScreen() async throws {
        let app = AppState()
        let w = window(app)
        w.setContentSize(NSSize(width: 1100, height: 700))
        w.contentView?.layoutSubtreeIfNeeded()
        try await busyDraft(app)
        for _ in 0..<10 {
            w.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let editor = try XCTUnwrap(textViews(in: try XCTUnwrap(w.contentView)).compactMap(\.enclosingScrollView).first { $0.frame.width > 300 })
        let box = editor.convert(editor.bounds, to: nil)
        let content = try XCTUnwrap(w.contentView).bounds
        print("LAYOUT \(app.documents.notes.count) meldingen, venster \(w.frame.size), minimum \(w.contentMinSize), bewerker \(box), inhoud \(content), past \(w.contentView?.fittingSize ?? .zero)")
        XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(box), "the editor stays inside the window")
        XCTAssertGreaterThan(box.height, 80, "and keeps room to read")
        XCTAssertGreaterThan(app.documents.notes.count, 20)
        // 680 and the title bar: what there is to report must not raise the window's minimum
        XCTAssertLessThanOrEqual(w.contentMinSize.height, 720)
        XCTAssertEqual(w.contentMinSize.width, 1000, accuracy: 1)
        XCTAssertLessThanOrEqual(w.frame.height, 720)
        Settings.shared.documentFolder = ""
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    /// A long document: the editor scrolls, and everything around it stays inside the window.
    func testALongDocumentStaysInsideTheWindow() async throws {
        let app = AppState()
        let s = app.documents
        s.choose(folder: folder)
        let w = window(app)
        w.setContentSize(NSSize(width: 1291, height: 841))
        s.newDocument(name: "Lang")
        w.contentView?.layoutSubtreeIfNeeded()
        for length in [200, 4000] {
            s.text = (1...length).map { "Regel \($0) van een lang document met tekst die doorloopt op de volgende regel van het scherm." }.joined(separator: "\n\n")
            for _ in 0..<8 {
                w.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let editors = textViews(in: try XCTUnwrap(w.contentView)).compactMap(\.enclosingScrollView).filter { $0.frame.width > 300 }
            let editor = try XCTUnwrap(editors.first)
            let box = editor.convert(editor.bounds, to: nil)
            let content = try XCTUnwrap(w.contentView).bounds
            print("LAYOUT \(length) regels: bewerker \(box), venster \(content), past \(w.contentView?.fittingSize ?? .zero)")
            XCTAssertTrue(content.insetBy(dx: -1, dy: -1).contains(box), "the editor stays inside the window")
            XCTAssertLessThan(box.height, content.height - 100, "and leaves room for the buttons")
        }
        Settings.shared.documentFolder = ""
    }
}
