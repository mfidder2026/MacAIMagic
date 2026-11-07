import XCTest
import SwiftUI
@testable import MacAIMagic

final class MemoryPlannerTests: XCTestCase {
    /// DeepSeek Compact as measured from its headers: ~9.3 GB dense, 40 layers of ~2.65 GB experts.
    private func compactDeepSeek() -> GGUFIndex {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt64(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_300_000_000))
        for il in 0..<40 {
            idx.tensors.append(.init(name: "blk.\(il).ffn_gate_exps.weight", bytes: 884_000_000))
            idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 884_000_000))
            idx.tensors.append(.init(name: "blk.\(il).ffn_down_exps.weight", bytes: 884_000_000))
        }
        idx.tensors.append(.init(name: "blk.1.engram_embd.weight", bytes: 80_600_000_000))
        return idx
    }

    private func mac(limitMB: Int) -> SystemInfo {
        SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                   gpuWorkingSet: 103_000_000_000, wiredLimitMB: limitMB, freeDisk: 1_000_000_000_000)
    }

    func testDefaultLimitPutsSomeExpertsOnCPU() {
        let p = MemoryPlanner.plan(index: compactDeepSeek(), system: mac(limitMB: 0), contextSize: 65_536, vision: true)
        XCTAssertGreaterThan(p.cpuMoELayers, 0)
        XCTAssertLessThan(p.cpuMoELayers, 40)
        XCTAssertLessThanOrEqual(p.dense + p.overhead + p.gpuExperts, p.gpuLimit)
        XCTAssertEqual(p.gpuExperts + p.cpuExperts, p.experts)
        XCTAssertFalse(p.warnings.isEmpty, "should suggest raising the wired limit")
    }

    func testRaisedLimitMovesMoreToGPU() {
        let low = MemoryPlanner.plan(index: compactDeepSeek(), system: mac(limitMB: 0), contextSize: 65_536, vision: true)
        let high = MemoryPlanner.plan(index: compactDeepSeek(), system: mac(limitMB: 123_000), contextSize: 65_536, vision: true)
        XCTAssertLessThan(high.cpuMoELayers, low.cpuMoELayers)
        XCTAssertEqual(high.engram, 80_600_000_000)
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let blocks = MarkdownText.blocks("# Titel\nHallo **wereld**\n\n```swift\nlet x = 1\n```\n- punt")
        XCTAssertEqual(blocks.count, 4)
        if case .heading(1, "Titel") = blocks[0] {} else { XCTFail("heading") }
        if case .code("swift", "let x = 1") = blocks[2] {} else { XCTFail("code") }
        if case .text(let t) = blocks[3] { XCTAssertEqual(t, "• punt") } else { XCTFail("bullet") }
    }
}

final class WebToolTests: XCTestCase {
    func testDuckDuckGoParsing() {
        let html = """
        <div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=x">Example &amp; Co</a>
        <a class="result__snippet" href="x">Een <b>voorbeeld</b> snippet</a></div>
        """
        let hits = WebTools.parseDuckDuckGo(html)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.url, "https://example.com/a")
        XCTAssertEqual(hits.first?.title, "Example & Co")
        XCTAssertEqual(hits.first?.snippet, "Een voorbeeld snippet")
    }

    func testHTMLText() {
        let t = HTML.text(from: "<p>Hallo</p><script>x()</script><p>wereld&nbsp;!</p>")
        XCTAssertEqual(t, "Hallo\nwereld !")
    }
}

final class GGUFIndexTests: XCTestCase {
    /// Indexes the real DeepSeek Compact headers when they are on disk (the download writes them first).
    func testRealHeadersIfPresent() throws {
        let model = try XCTUnwrap(ModelCatalog.shared.model("deepseek-v4.1-flash-compact"))
        let urls = model.files.map { Paths.modelDir(model.id).appendingPathComponent($0.local) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("model not downloaded") }
        let idx = try GGUFIndex.load(shards: urls, sizes: model.files.map(\.size))
        XCTAssertEqual(idx.layerCount, 40)
        XCTAssertEqual(idx.expertBytesPerLayer.count, 40)
        XCTAssertGreaterThan(idx.engramBytes, 150_000_000_000)
        let total = idx.denseBytes + idx.expertBytesPerLayer.values.reduce(0, +)
        XCTAssertEqual(Double(total) / 1e9, 115.3, accuracy: 2.0)
    }
}

final class CatalogTests: XCTestCase {
    func testCatalogLoads() throws {
        let c = ModelCatalog.shared
        XCTAssertEqual(c.models.count, 8)
        for m in c.models {
            XCTAssertFalse(m.files.isEmpty)
            XCTAssertNotNil(c.vision(for: m), m.id)
            XCTAssertNotNil(m.memory, m.id)
            XCTAssertNotNil(m.dense, m.id)
            // llama.cpp finds the other shards from the first one's name: <prefix>-0000N-of-0000M.gguf
            for (i, f) in m.files.enumerated() where m.files.count > 1 {
                XCTAssertTrue(f.local.hasPrefix(m.id), f.local)
                XCTAssertTrue(f.local.hasSuffix(String(format: "-%05d-of-%05d.gguf", i + 1, m.files.count)), f.local)
            }
        }
    }

    /// The names the user sees are our own: the model name starts with the base model, files are named after the id.
    func testNamesAreOurOwn() {
        for m in ModelCatalog.shared.models {
            XCTAssertTrue(["DeepSeek-V4.1-Flash", "GLM-5.3-Flash", "Qwen3.8-Flash-Next", "Qwen3.6-35B-A3B", "Ministral-3-8B"].contains { m.name.hasPrefix($0) }, m.name)
            XCTAssertTrue(m.files.allSatisfy { $0.local.hasPrefix(m.id) })
        }
    }
}

final class StreamingPlanTests: XCTestCase {
    /// A Q4-sized model (~290 GB of experts) on a 128 GB Mac: every expert stays mapped, the GPU caches the most used.
    func testLargerThanMemory() {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt32(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_000_000_000))
        for il in 0..<40 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 7_250_000_000)) }
        let mac = SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                             gpuWorkingSet: 103_000_000_000, wiredLimitMB: 122_880, freeDisk: 1_000_000_000_000)
        let p = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false)
        XCTAssertFalse(p.fitsInMemory)
        XCTAssertEqual(p.cpuMoELayers, 40, "all experts stay mapped from the file")
        XCTAssertTrue(p.tensorSplit.isEmpty)
        XCTAssertGreaterThan(p.expertCache, 90_000_000_000)
        XCTAssertGreaterThan(p.streamedExperts, 150_000_000_000)
        // the GPU holds the dense weights, buffers and the cache, and macOS keeps its headroom and staging page cache
        XCTAssertLessThanOrEqual(p.dense + p.overhead + p.expertCache, p.gpuLimit)
        XCTAssertLessThanOrEqual(p.dense + p.overhead + p.expertCache + MemoryPlanner.osHeadroom + MemoryPlanner.stagingReserve(p.physical), p.physical)
    }

    /// With the macOS default GPU limit the cache is smaller, and the plan suggests raising the limit.
    func testDefaultLimitShrinksCache() {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt32(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_000_000_000))
        for il in 0..<40 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 7_250_000_000)) }
        let mac = SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                             gpuWorkingSet: 103_000_000_000, wiredLimitMB: 0, freeDisk: 1_000_000_000_000)
        let p = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false)
        XCTAssertLessThan(p.dense + p.overhead + p.expertCache, 103_000_000_000)
        XCTAssertGreaterThan(p.expertCache, 75_000_000_000)
        XCTAssertTrue(p.warnings.contains { $0.contains("Verhoog de GPU-limiet") })
    }
}

/// Prints the memory plan of every model whose headers are on disk (MACAIMAGIC_PLANS=1).
@MainActor
final class PlanReportTests: XCTestCase {
    func testPrintPlans() throws {
        guard ProcessInfo.processInfo.environment["MACAIMAGIC_PLANS"] == "1" else { throw XCTSkip("set MACAIMAGIC_PLANS=1") }
        let store = ModelStore()
        for m in ModelCatalog.shared.models where store.status(m.id).headersAvailable {
            let idx = try GGUFIndex.load(shards: store.shardURLs(m), sizes: m.files.map(\.size))
            let p = MemoryPlanner.plan(index: idx, system: .current(), contextSize: 65_536, vision: true)
            print(String(format: "PLAN %@: layers %d, dense %.1f GB, experts %.1f GB, engram %.1f GB, cpu layers %d, gpu experts %.1f GB, cpu experts %.1f GB, expert cache %.1f GB, streamed %.1f GB, fits %@",
                         m.id, p.layers, Double(p.dense) / 1e9, Double(p.experts) / 1e9, Double(p.engram) / 1e9, p.cpuMoELayers,
                         Double(p.gpuExperts) / 1e9, Double(p.cpuExperts) / 1e9, Double(p.expertCache) / 1e9, Double(p.streamedExperts) / 1e9, p.fitsInMemory ? "yes" : "no"))
        }
    }
}

final class ClusterPlanTests: XCTestCase {
    private let mac = SystemInfo(chip: "Apple M3 Max", physicalMemory: 137_438_953_472, performanceCores: 12,
                                 gpuWorkingSet: 115_400_000_000, wiredLimitMB: 0, freeDisk: 1_000_000_000_000)
    /// M5 96 GB (GPU ~72 GB) and M1 32 GB (GPU ~21 GB), minus their own headroom as ClusterController counts it
    private let helpers: [UInt64] = [69_000_000_000, 18_000_000_000]

    /// GLM-5.3-Flash Q4 (~190 GB of experts) on the MacBook alone streams from the SSD; with the helpers it fits in memory.
    func testHelpersMakeQ4Fit() {
        var idx = GGUFIndex()
        idx.metadata["glm5-next.block_count"] = UInt32(46)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_800_000_000))
        for il in 3..<46 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 4_416_000_000)) }
        let alone = MemoryPlanner.plan(index: idx, system: mac, contextSize: 65_536, vision: false)
        XCTAssertFalse(alone.fitsInMemory)
        let cluster = MemoryPlanner.plan(index: idx, system: mac, contextSize: 65_536, vision: false, helpers: helpers)
        XCTAssertTrue(cluster.fitsInMemory)
        XCTAssertEqual(cluster.streamedExperts, 0, "nothing comes from the SSD")
        // one entry per helper and one for this Mac, together every layer plus the output layer
        XCTAssertEqual(cluster.tensorSplit.count, 3)
        XCTAssertEqual(cluster.tensorSplit.reduce(0, +), 47)
        // the helpers take the first layers, so the layers this Mac keeps in memory are among its own, the last ones
        let mine = (46 - (cluster.tensorSplit.last! - 1))..<46
        XCTAssertTrue(cluster.hostExpertLayers.allSatisfy { mine.contains($0) })
        XCTAssertLessThanOrEqual(cluster.cpuMoELayers, 6)
    }

    /// DeepSeek-V4.1-Flash Q4 (~290 GB of experts) does not fit even in the cluster: this Mac keeps its layers mapped
    /// and caches the most used experts, with a much larger share of its experts in the cache than alone.
    func testDeepSeekQ4StreamsLessInCluster() {
        var idx = GGUFIndex()
        idx.metadata["deepseek41.block_count"] = UInt32(40)
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_000_000_000))
        for il in 0..<40 { idx.tensors.append(.init(name: "blk.\(il).ffn_up_exps.weight", bytes: 7_250_000_000)) }
        let alone = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false)
        let cluster = MemoryPlanner.plan(index: idx, system: mac, contextSize: 32_768, vision: false, helpers: helpers)
        XCTAssertGreaterThan(cluster.expertCache, 0)
        XCTAssertLessThan(cluster.streamedExperts, alone.streamedExperts - 70_000_000_000)
        XCTAssertEqual(cluster.hostExpertLayers.count, cluster.tensorSplit.last! - 1, "all of this Mac's layers")
        XCTAssertEqual(cluster.hostExpertLayers.first, 40 - cluster.hostExpertLayers.count)
    }
}

/// Opening an earlier conversation shows its last message, also when the messages differ a lot in height and the chat
/// opens with the pane transition (switching from another screen); a short conversation starts at the top.
@MainActor
final class ChatScrollTests: XCTestCase {
    /// As in RootView: another pane first, then the chat, with the same transition and animation.
    private struct PaneSwitch: View {
        let target: Conversation.ID
        @State private var pane: Pane? = .live
        var body: some View {
            ZStack {
                Group {
                    switch pane {
                    case .chat(let id)?: ChatView(conversationID: id).id(id)
                    default: LiveView()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            .animation(.easeInOut(duration: 0.25), value: pane)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pane = .chat(target) } }
        }
    }

    /// Shaped like a real working session: tool calls and results, steps, an image, long thinking, code.
    private func longConversation() -> Conversation {
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let jpeg = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [:])!
        let prose = { (n: Int) in String(repeating: "Een zin met uitleg over het programma en wat het doet. ", count: n) }
        let code = "```basic\n" + (1...30).map { "\($0 * 10) PRINT \"REGEL \($0)\"" }.joined(separator: "\n") + "\n```"
        var c = Conversation(title: "Lang gesprek")
        for round in 0..<2 {
            c.messages += [
                ChatMessage(role: .user, text: prose(7)),
                ChatMessage(role: .assistant, text: prose(2), toolCalls: [ToolCall(id: "a\(round)", name: "list_dir", arguments: "{}")]),
                ChatMessage(role: .tool, text: "ok", toolCallId: "a\(round)"),
                ChatMessage(role: .assistant, text: prose(18), activities: (0..<3).map { ToolActivity(label: "Bestand schrijven: prog\($0).bas", done: true, output: prose(3)) }),
                ChatMessage(role: .user, text: "Start het programma"),
                ChatMessage(role: .assistant, text: prose(4) + "\n" + code),
                ChatMessage(role: .assistant, text: prose(10) + "\n" + code + "\n" + code, reasoning: prose(14),
                            activities: (0..<2).map { ToolActivity(label: "Commando: run \($0)", done: true) }),
                ChatMessage(role: .user, text: "Wat zie je op deze afbeelding?", attachments: [Attachment(filename: "scherm.jpg", jpeg: jpeg)]),
                ChatMessage(role: .assistant, text: "", reasoning: prose(360)),
                ChatMessage(role: .user, text: "Leg het nog eens uit"),
                ChatMessage(role: .assistant, text: prose(25) + "\n" + code + "\n" + code, reasoning: prose(200)),
            ]
        }
        return c
    }

    /// Shows the view in a window and returns the chat's scroll view, after the layout has settled.
    private func show(_ view: some View, app: AppState, wait: TimeInterval) throws -> NSScrollView {
        let root = view
            .environmentObject(app).environmentObject(app.engine).environmentObject(app.models)
            .environmentObject(app.store).environmentObject(app.chat).environmentObject(Settings.shared)
            .environmentObject(app.metrics).environmentObject(app.bench).environmentObject(app.cluster)
            .frame(width: 1000, height: 700)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        func scrollViews(in view: NSView) -> [NSScrollView] {
            var found = view.subviews.flatMap { scrollViews(in: $0) }
            if let s = view as? NSScrollView { found.append(s) }
            return found
        }
        return try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    /// Points between the bottom of the visible part and the end of the conversation.
    private func distanceFromEnd(_ scroll: NSScrollView) throws -> CGFloat {
        let doc = try XCTUnwrap(scroll.documentView)
        let visible = scroll.contentView.documentVisibleRect
        XCTAssertGreaterThan(doc.frame.height, visible.height * 3, "the conversation is longer than the window")
        return doc.isFlipped ? doc.frame.height - visible.maxY : visible.minY
    }

    func testOpensAtLastMessage() throws {
        let app = AppState()
        let c = longConversation()
        // in memory only: the saved conversations stay as they are
        app.store.conversations = [c]
        app.store.selection = c.id
        let fromEnd = try distanceFromEnd(show(ChatView(conversationID: c.id), app: app, wait: 1.5))
        XCTAssertLessThan(fromEnd, 40, "opened \(Int(fromEnd)) points above the last message")
    }

    func testOpensAtLastMessageAfterPaneSwitch() throws {
        let app = AppState()
        let c = longConversation()
        app.store.conversations = [c]
        app.store.selection = c.id
        let fromEnd = try distanceFromEnd(show(PaneSwitch(target: c.id), app: app, wait: 2.5))
        XCTAssertLessThan(fromEnd, 40, "opened \(Int(fromEnd)) points above the last message")
    }

    func testShortConversationStartsAtTop() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("macOS 14 aligns a short chat at the bottom") }
        let app = AppState()
        var c = Conversation(title: "Kort")
        c.messages = [ChatMessage(role: .user, text: "Hallo"), ChatMessage(role: .assistant, text: "Hoi! Waarmee kan ik helpen?")]
        app.store.conversations = [c]
        let scroll = try show(ChatView(conversationID: c.id), app: app, wait: 1.5)
        let doc = try XCTUnwrap(scroll.documentView)
        let inClip = doc.convert(doc.bounds, to: scroll.contentView)
        let top = scroll.contentView.isFlipped ? inClip.minY : scroll.contentView.bounds.height - inClip.maxY
        XCTAssertLessThan(top, 10, "a short chat starts \(Int(top)) points below the top")
    }
}

final class LocalizationTests: XCTestCase {
    private func with(_ lang: AppLanguage, _ body: () -> Void) {
        let saved = Settings.shared.language
        Settings.shared.language = lang.rawValue
        defer { Settings.shared.language = saved }
        body()
    }

    func testTranslatesWithValues() {
        let n = 12
        with(.en) { XCTAssertEqual(L("\(n) lagen CPU"), "12 layers on CPU") }
        with(.de) { XCTAssertEqual(L("Temperatuur \(0.7, specifier: "%.1f")"), "Temperatur 0.7") }
        with(.fr) { XCTAssertEqual(L("Nieuw gesprek"), "Nouvelle conversation") }
        with(.nl) { XCTAssertEqual(L("Bij \(80)% wordt het begin automatisch samengevat; de berichten blijven zichtbaar."),
                                   "Bij 80% wordt het begin automatisch samengevat; de berichten blijven zichtbaar.") }
        with(.en) { XCTAssertEqual(L("Bij \(80)% wordt het begin automatisch samengevat; de berichten blijven zichtbaar."),
                                   "At 80% the start is summarized automatically; the messages stay visible.") }
        // an unknown text stays as it is
        with(.de) { XCTAssertEqual(L("Iets dat nog niet vertaald is"), "Iets dat nog niet vertaald is") }
    }

    func testEveryLanguageHasEveryKey() {
        let en = Translations.table["en"] ?? [:]
        XCTAssertGreaterThan(en.count, 200)
        XCTAssertEqual(Translations.table["de"]?.count, en.count)
        XCTAssertEqual(Translations.table["fr"]?.count, en.count)
    }
}

/// Pasting in the chat field: an image becomes an attachment, text stays text.
final class PasteTests: XCTestCase {
    func testImageAndTextOnPasteboard() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("mds-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 200, height: 120), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        pb.clearContents()
        pb.writeObjects([image])
        XCTAssertEqual(ImageAttachment.fromPasteboard(pb)?.count, 1, "a screenshot or copied image")
        pb.clearContents()
        pb.setString("gewone tekst", forType: .string)
        XCTAssertNil(ImageAttachment.fromPasteboard(pb), "text pastes as text")
        pb.clearContents()
        pb.writeObjects([image])
        pb.setString("tekst met een plaatje van zichzelf", forType: .string)
        XCTAssertNil(ImageAttachment.fromPasteboard(pb), "copied rich text stays text")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mds-paste-\(UUID().uuidString).png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        XCTAssertEqual(ImageAttachment.fromPasteboard(pb)?.count, 1, "an image file copied in the Finder")
    }
}

/// The app works out per Mac which model fits and how: the Mac Studio M1 (32 GB), the Mac Studio M5 (96 GB), the MacBook (128 GB).
final class MachineFitTests: XCTestCase {
    private func mac(_ gib: UInt64, gpuShare: Double = 0.75) -> SystemInfo {
        let bytes = gib << 30
        return SystemInfo(chip: "Apple M1 Max", physicalMemory: bytes, performanceCores: 8,
                          gpuWorkingSet: UInt64(Double(bytes) * gpuShare), wiredLimitMB: 0, freeDisk: 1_000_000_000_000)
    }

    func testRecommendedModelPerMac() {
        let models = ModelCatalog.shared.models
        XCTAssertEqual(SystemCheck.recommended(models, physical: mac(32).physicalMemory)?.id, "qwen3.6-35b-a3b-q4")
        XCTAssertEqual(SystemCheck.recommended(models, physical: mac(96).physicalMemory)?.id, "qwen3.8-flash-next-q4")
        XCTAssertEqual(SystemCheck.recommended(models, physical: mac(128).physicalMemory)?.id, "deepseek-v4.1-flash-compact")
        XCTAssertEqual(SystemCheck.recommended(models, physical: mac(16).physicalMemory)?.id, "ministral-3-8b-q4", "16 GB: the model that fits whole")
        XCTAssertEqual(SystemCheck.recommended(models, physical: mac(8).physicalMemory)?.id, "ministral-3-8b-q4", "8 GB: it streams")
        // Heretic is a choice, never the recommendation: also not on a Mac where it fits and the original does not
        let heretic = models.first { $0.id == "qwen3.6-35b-a3b-heretic-q4" }
        XCTAssertEqual(heretic?.recommend, false)
        for gb: UInt64 in [8, 16, 24, 32, 48, 64, 96, 128] {
            XCTAssertNotEqual(SystemCheck.recommended(models.filter { $0.id != "qwen3.6-35b-a3b-q4" }, physical: mac(gb).physicalMemory)?.id,
                              "qwen3.6-35b-a3b-heretic-q4", "\(gb) GB")
        }
    }

    func testFitPerMac() {
        let byID = Dictionary(uniqueKeysWithValues: ModelCatalog.shared.models.map { ($0.id, $0) })
        let small = mac(32).physicalMemory, big = mac(128).physicalMemory
        // both Qwen3.6 versions (the original and Heretic, without refusals) fit whole on 32 GB
        let fitOn32 = ["qwen3.6-35b-a3b-q4", "qwen3.6-35b-a3b-heretic-q4"]
        for id in fitOn32 { XCTAssertEqual(MemoryPlanner.fit(byID[id]!, physical: small), .fits, id) }
        // larger than memory is what the app is for: everything else streams on 32 GB, nothing is too big
        for m in ModelCatalog.shared.models where !fitOn32.contains(m.id) && !m.isPlain {
            XCTAssertEqual(MemoryPlanner.fit(m, physical: small), .streams, m.id)
        }
        XCTAssertEqual(MemoryPlanner.fit(byID["glm-5.3-flash-q4"]!, physical: mac(16).physicalMemory), .tooBig)
        XCTAssertEqual(MemoryPlanner.fit(byID["deepseek-v4.1-flash-compact"]!, physical: big), .fits)
        XCTAssertEqual(MemoryPlanner.fit(byID["deepseek-v4.1-flash-q4"]!, physical: big), .streams)
        XCTAssertEqual(MemoryPlanner.fit(byID["glm-5.3-flash-compact"]!, physical: mac(96).physicalMemory), .streams)
    }

    /// Qwen3.6 on 32 GB, planned from the real file: a smaller context, no vision, the whole model in memory.
    @MainActor func testQwenOn32GB() throws {
        let file = Paths.modelsRoot.appendingPathComponent("qwen3.6-35b-a3b-q4/qwen3.6-35b-a3b-q4.gguf")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Qwen3.6 not downloaded") }
        let index = try GGUFIndex.load(shards: [file], sizes: [22_360_456_160])
        let m1 = mac(32, gpuShare: 0.67)
        let withVision = MemoryPlanner.contextRoom(index: index, system: m1, vision: true) ?? 0
        let room = try XCTUnwrap(MemoryPlanner.contextRoom(index: index, system: m1, vision: false))
        print("32 GB: context \(room) without vision, \(withVision) with")
        XCTAssertLessThan(withVision, 16_384, "vision leaves too little room on 32 GB")
        XCTAssertGreaterThanOrEqual(room, 16_384)
        let plan = MemoryPlanner.plan(index: index, system: m1, contextSize: min(65_536, room), vision: false)
        XCTAssertTrue(plan.fitsInMemory)
        print("32 GB plan: context \(plan.contextSize), GPU limit \(plan.gpuLimit.gb), experts on CPU in \(plan.cpuMoELayers) layers, suggested limit \(plan.suggestedWiredLimitMB) MB")
        let raised = MemoryPlanner.plan(index: index, system: SystemInfo(chip: m1.chip, physicalMemory: m1.physicalMemory, performanceCores: 8,
                                        gpuWorkingSet: m1.gpuWorkingSet, wiredLimitMB: plan.suggestedWiredLimitMB, freeDisk: m1.freeDisk),
                                        contextSize: min(65_536, room), vision: false)
        print("32 GB with raised limit: experts on CPU in \(raised.cpuMoELayers) layers")
        XCTAssertLessThanOrEqual(raised.cpuMoELayers, plan.cpuMoELayers)
    }

    /// Every model that does not fit starts on 32 GB with a real expert cache, not with page faults.
    @MainActor func testStreamingPlansOn32GB() throws {
        let store = ModelStore()
        let m1 = mac(32, gpuShare: 0.67)
        var checked = 0
        // the two Qwen3.6 versions fit whole on 32 GB (testFitPerMac), so they are not streaming plans
        let fitOn32 = ["qwen3.6-35b-a3b-q4", "qwen3.6-35b-a3b-heretic-q4"]
        for m in ModelCatalog.shared.models where !fitOn32.contains(m.id) && !m.isPlain && store.status(m.id).isComplete {
            let index = try GGUFIndex.load(shards: store.shardURLs(m), sizes: m.files.map(\.size))
            XCTAssertFalse(MemoryPlanner.fitsWhole(index: index, system: m1), m.id)
            let context = try XCTUnwrap(MemoryPlanner.contextRoom(index: index, system: m1, vision: false))
            let plan = MemoryPlanner.plan(index: index, system: m1, contextSize: context, vision: false)
            print("PLAN32 \(m.id) cache-mib=\(plan.expertCache >> 20) context=\(plan.contextSize) dense=\(plan.dense.gb) warnings=\(plan.warnings.count)")
            XCTAssertGreaterThanOrEqual(plan.expertCache, MemoryPlanner.minimumCache, m.id)
            XCTAssertLessThanOrEqual(plan.dense + plan.expertCache, plan.gpuLimit, m.id)
            checked += 1
        }
        if checked == 0 { throw XCTSkip("no large model downloaded") }
    }

    /// A Mac with little memory never underflows when the reserves are larger than what it has.
    func testVerySmallMacDoesNotCrash() {
        var idx = GGUFIndex()
        idx.tensors.append(.init(name: "token_embd.weight", bytes: 9_000_000_000))
        idx.tensors.append(.init(name: "blk.0.ffn_up_exps.weight", bytes: 100_000_000_000))
        let plan = MemoryPlanner.plan(index: idx, system: mac(8), contextSize: 4096, vision: false, inUse: 7 << 30)
        XCTAssertEqual(plan.expertCache, 0)
    }
}

/// The model must not fall silent while its work is not done (the sentences come from a real conversation on the Mac Studio).
final class UnfinishedTurnTests: XCTestCase {
    private func check(_ text: String, reasoning: String = "", cutOff: Bool = false, working: Bool = true) -> Bool {
        ChatClient.looksUnfinished(text: text, reasoning: reasoning, cutOff: cutOff, working: working)
    }

    func testStopsThatAreNotTheEnd() {
        XCTAssertTrue(check("Sorry, ik ben gewoon doorgegaan! Ik maak nu een werkend .d64 disk image met het spel en start de emulator."))
        XCTAssertTrue(check("Mijn script is mislukt door een error. Laat me het debuggen en een alternatieve aanpak proberen:"))
        XCTAssertTrue(check("", reasoning: "Python3 werkt niet.\nLaten we kijken of c1541 beschikbaar is.\n</parameter>\n</function>\n</tool_call>"), "only thinking")
        XCTAssertTrue(check("Ik kijk even.", reasoning: "c1541 zoeken\n</parameter>\n</function>\n</tool_call>"), "a tool call left in the thinking")
        XCTAssertTrue(check("Let me try another way."))
        XCTAssertTrue(check("half antwoord", cutOff: true, working: false), "the context was full")
    }

    /// The done-word is for the app; the user sees the answer without it (the first one is from the calendar connector).
    func testDoneWordIsNotShown() {
        XCTAssertEqual(ChatClient.withoutDoneWord("KLAAR — morgen (zondag 8 november 2026) staat er niets in je agenda."),
                       "Morgen (zondag 8 november 2026) staat er niets in je agenda.")
        XCTAssertEqual(ChatClient.withoutDoneWord("KLAAR: het spel draait in VICE."), "Het spel draait in VICE.")
        XCTAssertEqual(ChatClient.withoutDoneWord("**KLAAR**\n\nHet staat in uit.txt."), "Het staat in uit.txt.")
        XCTAssertEqual(ChatClient.withoutDoneWord("DONE. The file is written."), "The file is written.")
        XCTAssertEqual(ChatClient.withoutDoneWord("Klaar! Het bestand is er."), "Klaar! Het bestand is er.", "ordinary language stays")
        XCTAssertEqual(ChatClient.withoutDoneWord("KLAARZETTEN gaat zo."), "KLAARZETTEN gaat zo.")
        XCTAssertEqual(ChatClient.withoutDoneWord("KLAAR"), "KLAAR", "nothing after it: leave it")
    }

    /// After steps only the model's own word ends a task; the remark below ended a real conversation on the Mac Studio.
    func testARemarkIsNoEnding() {
        XCTAssertTrue(ChatClient.looksUnfinished(text: "dtruss levert geen uitvoer, exit code 0. Dit werkt niet lekker.", reasoning: "", cutOff: false, working: true, tookSteps: true))
        XCTAssertFalse(ChatClient.looksUnfinished(text: "KLAAR: het spel draait in VICE.", reasoning: "", cutOff: false, working: true, tookSteps: true))
        XCTAssertFalse(ChatClient.looksUnfinished(text: "**Klaar!** Het staat in uit.txt.", reasoning: "", cutOff: false, working: true, tookSteps: true))
        XCTAssertFalse(ChatClient.looksUnfinished(text: "DONE. The file is written.", reasoning: "", cutOff: false, working: true, tookSteps: true))
        XCTAssertFalse(ChatClient.looksUnfinished(text: "Welke map bedoel je?", reasoning: "", cutOff: false, working: true, tookSteps: true), "a question to the user")
        XCTAssertFalse(ChatClient.looksUnfinished(text: "2 + 2 is 4.", reasoning: "", cutOff: false, working: true, tookSteps: false), "no steps taken: a plain answer")
    }

    func testRealEndings() {
        XCTAssertFalse(check("Het spel staat in avontuur.prg en draait in VICE."))
        XCTAssertFalse(check("Klaar! Wil je dat ik nog een kamer toevoeg?"))
        XCTAssertFalse(check("Dat is alles. Laat me weten als je nog iets wilt veranderen."))
        XCTAssertFalse(check("Let me know if you want more rooms."))
        XCTAssertFalse(check("Ik zal het doen.", working: false), "a plain chat without tools just ends")
    }
}

/// MACAIMAGIC.md: made when it is missing, keeps the user's text, and what was learned does not pile up without end.
final class WorkspaceNotesTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMadeWhenMissingAndLessonsAdded() throws {
        let f = try folder()
        WorkspaceNotes.createIfNeeded(in: f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.appendingPathComponent("MACAIMAGIC.md").path))
        XCTAssertEqual(WorkspaceNotes.add(lessons: ["- python3 werkt hier niet", "- VICE staat in /Applications"], in: f).count, 2)
        XCTAssertEqual(WorkspaceNotes.add(lessons: ["- PYTHON3 werkt hier niet"], in: f).count, 0, "known already")
        XCTAssertTrue(WorkspaceNotes.forPrompt(in: f)?.contains("- VICE staat in /Applications") == true)
    }

    func testUsersFileStaysAndFormerNameWorks() throws {
        let f = try folder()
        let former = f.appendingPathComponent("MAC" + "DEEPSEEK.md")
        try "Start VICE met open.".write(to: former, atomically: true, encoding: .utf8)
        WorkspaceNotes.createIfNeeded(in: f)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.appendingPathComponent("MACAIMAGIC.md").path), "the former file is the notes file")
        WorkspaceNotes.add(lessons: ["- iets geleerd"], in: f)
        let text = try String(contentsOf: former, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Start VICE met open."))
        XCTAssertTrue(text.contains("- iets geleerd"))
    }

    func testOldestLessonsGoFirst() throws {
        let f = try folder()
        for i in 1...(WorkspaceNotes.maxLessons + 5) { WorkspaceNotes.add(lessons: ["- les nummer \(i) van de reeks"], in: f) }
        let text = try XCTUnwrap(WorkspaceNotes.forPrompt(in: f))
        XCTAssertFalse(text.contains("- les nummer 1 van de reeks"))
        XCTAssertTrue(text.contains("- les nummer \(WorkspaceNotes.maxLessons + 5) van de reeks"))
    }

    func testOnlyLessonLinesCount() {
        XCTAssertEqual(WorkspaceNotes.lessons(from: "GEEN"), [])
        let answer = "Dit heb ik geleerd:\n- python3 ontbreekt op deze Mac\n- python3 ontbreekt op deze Mac\nTot slot iets anders."
        XCTAssertEqual(WorkspaceNotes.lessons(from: answer), ["- python3 ontbreekt op deze Mac"])
    }
}

/// A new chat must have the folder chosen last, or the model gets no tools and says it cannot work on this Mac.
/// In memory only: delete() and save() would write the real conversations file.
@MainActor
final class ChatFolderTests: XCTestCase {
    private var saved = ""

    override func setUp() async throws {
        saved = Settings.shared.workspace
        Settings.shared.workspace = "/tmp/laatste-map"
    }

    override func tearDown() async throws { Settings.shared.workspace = saved }

    func testEmptyChatWithoutFolderGetsTheLastFolder() {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        store.conversations = [Conversation()]
        store.newConversation()
        XCTAssertEqual(store.conversations.count, 1)
        XCTAssertEqual(store.conversations[0].workspace, "/tmp/laatste-map")
        XCTAssertEqual(store.selection, store.conversations[0].id)
    }

    func testNewChatAfterAChatGetsTheLastFolder() {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var old = Conversation(title: "Oud")
        old.messages = [ChatMessage(role: .user, text: "hallo")]
        store.conversations = [old]
        store.newConversation()
        XCTAssertEqual(store.conversations.count, 2)
        XCTAssertEqual(store.conversations[0].workspace, "/tmp/laatste-map")
        XCTAssertNil(store.conversations[1].workspace, "a chat with messages keeps what it had")
    }

    func testChatKeepsItsOwnFolder() {
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var own = Conversation()
        own.workspace = "/tmp/eigen-map"
        store.conversations = [own]
        store.newConversation()
        XCTAssertEqual(store.conversations[0].workspace, "/tmp/eigen-map")
    }

    func testNoFolderChosenYetLeavesTheChatWithout() {
        Settings.shared.workspace = ""
        let store = ConversationStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        store.conversations = [Conversation()]
        store.newConversation()
        XCTAssertNil(store.conversations[0].workspace)
    }

    func testOutsideTheFolderPointsToRunCommand() {
        XCTAssertTrue(WorkspaceTools.ToolError.outside("/Applications").localizedDescription.contains("run_command"))
    }
}

/// A Mac with 16 GB: the numbers only. Its behaviour has not been measured on a real one.
final class SmallMacTests: XCTestCase {
    private let sixteen: UInt64 = 16 << 30
    private func model(_ id: String) throws -> ModelInfo { try XCTUnwrap(ModelCatalog.shared.model(id)) }

    func testQwen36StreamsOn16GB() throws {
        XCTAssertEqual(MemoryPlanner.fit(try model("qwen3.6-35b-a3b-q4"), physical: sixteen), .streams)
        XCTAssertEqual(SystemCheck.recommended(ModelCatalog.shared.models, physical: sixteen)?.id, "ministral-3-8b-q4", "the small model fits whole, and goes first")
    }

    func testAMacWithLessKeepsWarningInsteadOfCrashing() throws {
        XCTAssertEqual(MemoryPlanner.fit(try model("qwen3.6-35b-a3b-q4"), physical: 8 << 30), .tooBig)
        XCTAssertEqual(SystemCheck.recommended(ModelCatalog.shared.models, physical: 8 << 30)?.id, "ministral-3-8b-q4")
    }

    func testLargerMacsKeepTheirMeasuredReserves() {
        for gb: UInt64 in [24, 32, 64, 128] {
            XCTAssertEqual(MemoryPlanner.streamingHeadroom(gb << 30), MemoryPlanner.osHeadroom)
            XCTAssertGreaterThanOrEqual(MemoryPlanner.stagingReserve(gb << 30), 4_500_000_000)
        }
    }

    @MainActor func testThePlanOn16GBLeavesMemoryFree() throws {
        let m = try model("qwen3.6-35b-a3b-q4")
        guard ModelStore().status(m.id).isComplete else { throw XCTSkip("Qwen3.6 not downloaded") }
        let index = try GGUFIndex.load(shards: ModelStore().shardURLs(m), sizes: m.files.map(\.size))
        let system = SystemInfo(chip: "Apple M2", physicalMemory: sixteen, performanceCores: 4, gpuWorkingSet: 12_000_000_000, wiredLimitMB: 0, freeDisk: 100_000_000_000)
        let context = try XCTUnwrap(MemoryPlanner.contextRoom(index: index, system: system, vision: false))
        XCTAssertEqual(context, MemoryPlanner.tinyMacContext)
        let plan = MemoryPlanner.plan(index: index, system: system, contextSize: context, vision: false)
        print("PLAN16 cache \(plan.expertCache) dense \(plan.dense) overhead \(plan.overhead)")
        XCTAssertGreaterThanOrEqual(plan.expertCache, 1_000_000_000, "a real expert cache, not only page faults")
        XCTAssertLessThanOrEqual(plan.expertCache, MemoryPlanner.largestCacheOnSmallMac)
        XCTAssertFalse(plan.fitsInMemory)
        // what is held fast must leave macOS and the apps at least the headroom
        XCTAssertLessThanOrEqual(plan.dense + plan.expertCache + plan.overhead + MemoryPlanner.streamingHeadroom(sixteen), sixteen)
        if let out = ProcessInfo.processInfo.environment["MACAIMAGIC_PLAN16"] {
            let args = EngineController().arguments(model: m, shards: ModelStore().shardURLs(m), plan: plan, vision: nil)
            try args.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

