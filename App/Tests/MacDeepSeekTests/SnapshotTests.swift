import XCTest
import SwiftUI
@testable import MacDeepSeek

/// Renders the main screens offscreen to PNG, for the README.
/// MACDEEPSEEK_SNAPSHOTS=<dir> renders with sample data; add MACDEEPSEEK_ENGINE_TEST=1 to fill the chats with real
/// answers from the running engine (web search, an image, thinking).
@MainActor
final class SnapshotTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        guard let d = ProcessInfo.processInfo.environment["MACDEEPSEEK_SNAPSHOTS"] else { throw XCTSkip("no snapshot dir") }
        dir = URL(fileURLWithPath: d)
    }

    private var live: Bool { ProcessInfo.processInfo.environment["MACDEEPSEEK_ENGINE_TEST"] == "1" }

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
            .environmentObject(app.metrics).environmentObject(app.bench)
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
