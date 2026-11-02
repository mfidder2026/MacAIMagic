import XCTest
import SwiftUI
@testable import MacAIMagic

/// Renders the main screens offscreen to PNG, for the README.
/// MACAIMAGIC_SNAPSHOTS=<dir> renders with sample data; add MACAIMAGIC_ENGINE_TEST=1 to fill the chats with real
/// answers from the running engine (web search, an image, thinking).
@MainActor
final class SnapshotTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        guard let d = ProcessInfo.processInfo.environment["MACAIMAGIC_SNAPSHOTS"] else { throw XCTSkip("no snapshot dir") }
        dir = URL(fileURLWithPath: d)
    }

    private var live: Bool { ProcessInfo.processInfo.environment["MACAIMAGIC_ENGINE_TEST"] == "1" }

    func testRenderScreens() async throws {
        let app = AppState()
        // show the model that really runs: the engine's alias is the model id
        var running = ModelCatalog.shared.models.first
        if live, let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:8080/v1/models")!),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = (json["data"] as? [[String: Any]])?.first?["id"] as? String {
            running = ModelCatalog.shared.model(id) ?? running
        }
        app.selectedModelID = running?.id ?? app.selectedModelID
        app.engine.previewState(live ? .running : .stopped, model: live ? running : nil)
        app.loadIndex()

        // the models screen first: the image chat below shows it to the model
        try shot(withBackground(ModelsView(), app: app), app: app, name: "models", dark: true)

        let search = try await conversation(app, "Zoek het laatste nieuws over llama.cpp en vat het samen in een paar punten.",
                                            thinking: false, web: true, fallback: sampleSearch())
        let image = try await conversation(app, "Wat zie je op deze schermafbeelding? Welke getallen vallen op?", thinking: false,
                                           web: false, image: dir.appendingPathComponent("models.png"), fallback: sampleSearch())
        let thinking = try await conversation(app, "Hoeveel weegt een liter lucht op zeeniveau, ongeveer? Reken het kort voor.",
                                              thinking: true, web: false, fallback: sampleSearch())
        app.store.conversations = [search, image, thinking]

        for (c, name) in [(search, "chat-search"), (image, "chat-image"), (thinking, "chat-thinking")] {
            app.store.selection = c.id
            let view = NavigationSplitView { Sidebar(pane: .constant(nil)) } detail: {
                withBackground(ChatView(conversationID: c.id, scrollToEnd: false), app: app)
            }
            try shot(view, app: app, name: name, dark: true)
        }
        // the live dashboard right after the last answer, so the charts show real activity
        let live = NavigationSplitView { Sidebar(pane: .constant(nil)) } detail: { withBackground(LiveView(), app: app) }
        try shot(live, app: app, name: "live", dark: true)
        try shot(withBackground(CompareView(), app: app), app: app, name: "compare", dark: true)
        try shot(withBackground(ClusterView(), app: app), app: app, name: "cluster", dark: true)
        try shot(SettingsView(), app: app, name: "settings", dark: true)

        // a long task: its steps are folded, and only the last answer carries them
        var long = Conversation(title: "Lange taak")
        long.messages = [ChatMessage(role: .user, text: "Maak een text adventure voor de Commodore 64."),
                         ChatMessage(role: .assistant, text: "Ik maak eerst het spel.", activities: []),
                         ChatMessage(role: .user, text: "x", automatic: true),
                         ChatMessage(role: .assistant, text: "Het spel staat in **adventure.prg** en draait in VICE.",
                                     activities: (1...37).map { ToolActivity(label: "Uitvoeren: stap \($0)", done: true, output: "ok") })]
        app.store.conversations = [long]
        app.store.selection = long.id
        try shot(withBackground(ChatView(conversationID: long.id, scrollToEnd: false), app: app), app: app, name: "chat-steps", dark: true)

        // the folder button: off in a chat without a folder, on with the folder's name in a chat that has one
        let tools = Settings.shared.workspaceTools
        Settings.shared.workspaceTools = true
        defer { Settings.shared.workspaceTools = tools }
        for (folder, name) in [(nil, "chat-no-folder"), ("/Users/gebruiker/Development/C64-project", "chat-folder")] as [(String?, String)] {
            var c = Conversation(title: "Werkmap")
            c.workspace = folder
            app.store.conversations = [c]
            app.store.selection = c.id
            try shot(withBackground(ChatView(conversationID: c.id, scrollToEnd: false), app: app), app: app, name: name, dark: true)
        }

        // the documents module with a real draft in it
        let projects = dir.appendingPathComponent("project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects) }
        app.documents.choose(folder: projects)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sjabloon.docx")
        app.documents.useHouseStyle(fixture)
        app.documents.addAttachment(fixture)
        app.documents.page = .project
        try shot(withBackground(DocumentsView(), app: app), app: app, name: "documents-project", dark: true)
        app.documents.page = .newDocument
        try shot(withBackground(DocumentsView(), app: app), app: app, name: "documents-new", dark: true)
        app.documents.newDocument(name: "Quick scan")
        app.documents.text = "---\ntitel: Quick scan\nKlant: Gemeente Voorbeeld\n---\n\n# Inleiding\n\nTekst van het concept.\n"
        try shot(withBackground(DocumentsView(), app: app), app: app, name: "documents", dark: true)

        // the models as the Mac Studio M1 sees them
        app.simulatedSystem = SystemInfo(chip: "Apple M1 Max", physicalMemory: 32 << 30, performanceCores: 8,
                                         gpuWorkingSet: 23_000_000_000, wiredLimitMB: 0, freeDisk: 900_000_000_000)
        try shot(withBackground(ModelsView(), app: app), app: app, name: "models-32gb", dark: true)
        app.selectedModelID = "qwen3.8-flash-next-q4"
        try shot(withBackground(ModelsView(), app: app), app: app, name: "models-32gb-qwen38", dark: true)
        await app.check.run(app: app)
        try shot(withBackground(SystemView { _ in }, app: app), app: app, name: "system-32gb", dark: true)
        app.selectedModelID = ModelCatalog.shared.models.first?.id ?? app.selectedModelID
        app.simulatedSystem = nil

        // the system check on this Mac, and as a clean Mac sees it: an empty models folder
        await app.check.run(app: app)
        try shot(withBackground(SystemView { _ in }, app: app), app: app, name: "system", dark: true)
        let saved = Settings.shared.modelFolder
        Settings.shared.modelFolder = dir.appendingPathComponent("empty-models").path
        await app.check.run(app: app)
        try shot(withBackground(SystemView { _ in }, app: app), app: app, name: "system-clean", dark: true)
        Settings.shared.modelFolder = saved
    }

    private func withBackground(_ v: some View, app: AppState) -> some View {
        ZStack { AuroraBackground(energy: 0.4); v }
    }

    /// One real exchange through the app's own ChatClient, or sample data without an engine.
    private func conversation(_ app: AppState, _ text: String, thinking: Bool, web: Bool, image: URL? = nil,
                              fallback: Conversation) async throws -> Conversation {
        guard live else { return fallback }
        Settings.shared.thinking = thinking
        Settings.shared.webSearch = web
        Settings.shared.reasoningEffort = "low"
        let c = Conversation()
        app.store.conversations.insert(c, at: 0)
        let attachments = image.flatMap { ImageAttachment.make(from: $0) }.map { [$0] } ?? []
        app.chat.send(text: text, attachments: attachments, in: c.id, store: app.store,
                      baseURL: URL(string: "http://127.0.0.1:8080")!)
        let start = Date()
        while app.chat.busy && Date().timeIntervalSince(start) < 900 { try await Task.sleep(for: .milliseconds(500)) }
        return try XCTUnwrap(app.store.conversations.first { $0.id == c.id })
    }

    private func shot(_ view: some View, app: AppState, name: String, dark: Bool) throws {
        let size = NSSize(width: 1180, height: 800)
        let root = view
            .environmentObject(app).environmentObject(app.engine).environmentObject(app.models)
            .environmentObject(app.store).environmentObject(app.chat).environmentObject(Settings.shared)
            .environmentObject(app.metrics).environmentObject(app.bench).environmentObject(app.cluster).environmentObject(app.check).environmentObject(app.documents)
            .tint(Theme.accent)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func sampleSearch() -> Conversation {
        var c = Conversation(title: "Voorbeeld")
        c.messages = [
            ChatMessage(role: .user, text: "Wat is er nieuw in llama.cpp?"),
            ChatMessage(role: .assistant, text: "## llama.cpp\n- **Metal**: snellere kernels\n```sh\nllama-server -m model.gguf\n```",
                        reasoning: "Ik zoek eerst.", activities: [ToolActivity(label: "Zoeken: llama.cpp nieuws", done: true)],
                        sources: [Source(title: "GitHub", url: "https://github.com/ggml-org/llama.cpp")], tokensPerSecond: 20.1),
        ]
        return c
    }
}
