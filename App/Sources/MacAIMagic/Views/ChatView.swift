import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let conversationID: Conversation.ID
    /// false shows the start of the conversation (README screenshots)
    var scrollToEnd = true
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var metrics: LiveMetrics
    @State private var draft = ""

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        VStack(spacing: 0) {
            LiveStrip()
            if let c = conversation, !c.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(c.messages.filter { !$0.isHidden }) { m in
                                MessageRow(message: m, streaming: chat.isBusy(conversationID) && m.id == c.messages.last?.id)
                                    .id(m.id)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                                if m.id == lastShownSummarized(c), let summary = c.summary { SummaryDivider(summary: summary) }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: c.messages.count)
                        .frame(maxWidth: 860)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollContentBackground(.hidden)
                    .modifier(OpenAtEnd(enabled: scrollToEnd))
                    .onChange(of: c.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: c.messages.last?.preparing) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    // the step card or an approval card below takes room: keep the last message above it
                    .onChange(of: belowKey) { _, _ in Self.scrollSoon(proxy) }
                    .onChange(of: (c.messages.last?.reasoning.count ?? 0) / 400) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: c.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    // back from another page: the anchor alone can land at the top while the lazy stack still guesses
                    // its heights; after the pane transition, go to the end once more, and again when heights are known
                    .task(id: conversationID) {
                        guard scrollToEnd else { return }
                        for wait in [350, 450] {
                            try? await Task.sleep(for: .milliseconds(wait))
                            if Task.isCancelled { return }
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            } else {
                EmptyChat(draft: $draft)
            }
            if let problem = store.loadProblem {
                Text(problem).font(.callout).foregroundStyle(Theme.amber).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if !engine.state.isRunning { EngineBanner(fast: app.documentEngines.fast) }
            if engine.state.isRunning && metrics.engineBusy && !chat.busy { OtherRequestBanner() }
            GateBanner(gate: chat.gate, conversationID: conversationID)
            // a finished list goes with the next question (ChatClient.send)
            if let steps = conversation?.steps, !steps.isEmpty {
                StepsCard(steps: steps, busy: chat.isBusy(conversationID))
            }
            if let a = chat.approvals[conversationID] { ApprovalCard(approval: a) }
            Composer(conversationID: conversationID, text: $draft)
        }
        .navigationTitle(conversation?.displayTitle ?? "MacAIMagic")
    }

    /// What sits between the messages and the input field (the step card, an approval card): when it changes, the
    /// view gets smaller and the end has to come into view again.
    private var belowKey: String {
        let steps = conversation?.steps?.map { $0.title + $0.status }.joined() ?? ""
        return steps + (chat.approvals[conversationID]?.id.uuidString ?? "")
    }

    private static func scrollSoon(_ proxy: ScrollViewProxy) {
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// The last visible message that the summary replaces (the divider goes under it).
    private func lastShownSummarized(_ c: Conversation) -> UUID? {
        guard let upTo = c.summaryUpTo, let i = c.messages.firstIndex(where: { $0.id == upTo }) else { return nil }
        return c.messages[...i].last { !$0.isHidden }?.id
    }
}

/// The engine answers one request at a time: a request from elsewhere (the API, a test) makes a new message wait.
private struct OtherRequestBanner: View {
    var body: some View {
        Label(L("De engine werkt aan een ander verzoek (bijvoorbeeld via de API). Een nieuw bericht wacht tot dat klaar is."),
              systemImage: "hourglass")
            .font(.callout).foregroundStyle(Theme.amber)
            .padding(.horizontal, 20).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.amber.opacity(0.08))
    }
}

/// This conversation waits while the model writes for another one of ours (a task, another chat).
private struct GateBanner: View {
    @ObservedObject var gate: ModelGate
    @EnvironmentObject var store: ConversationStore
    let conversationID: Conversation.ID

    var body: some View {
        if gate.waiting.contains(conversationID), let other = gate.holder, other != conversationID {
            let title = store.conversations.first { $0.id == other }?.displayTitle ?? ""
            Label(L("Wacht op het model: het schrijft nu in '\(title)'. Daarna is dit gesprek aan de beurt."), systemImage: "hourglass")
                .font(.callout).foregroundStyle(Theme.amber)
                .padding(.horizontal, 20).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.08))
        }
    }
}

/// Where a conversation was compacted: the messages above go to the model as a summary.
private struct SummaryDivider: View {
    let summary: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(Theme.amber.opacity(0.4)).frame(height: 1)
                Button { open.toggle() } label: {
                    Label(L("Hierboven samengevat om context vrij te maken"), systemImage: "rectangle.compress.vertical")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.amber)
                Rectangle().fill(Theme.amber.opacity(0.4)).frame(height: 1)
            }
            if open {
                MarkdownText(text: summary).font(.callout)
                    .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// How full the model's context is for this conversation, with a button to compact it.
private struct ContextMeter: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var engine: EngineController
    @State private var open = false

    private static func short(_ n: Int) -> String { n >= 1_048_576 ? "\(n / 1_048_576)M" : n >= 1000 ? "\(n / 1024)K" : "\(n)" }

    var body: some View {
        let used = store.current?.contextTokens ?? 0
        let limit = max(chat.contextLimit, 1)
        let share = min(Double(used) / Double(limit), 1)
        let color = share > 0.9 ? Color.red : share > ChatClient.compactAt * 0.85 ? Theme.amber : Theme.mint
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if chat.compacting || chat.learning { ProgressView().controlSize(.mini) }
                Text(chat.compacting ? L("Samenvatten…") : chat.learning ? L("Noteert wat het geleerd heeft…") : "\(Self.short(used)) / \(Self.short(limit))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                Capsule().fill(.white.opacity(0.12)).frame(width: 46, height: 5)
                    .overlay(alignment: .leading) { Capsule().fill(color).frame(width: 46 * share, height: 5) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Context")).font(.headline)
                Text(L("\(used) van \(limit) tokens gebruikt in dit gesprek")).font(.callout)
                Text(L("Bij \(Int(ChatClient.compactAt * 100))% wordt het begin automatisch samengevat; de berichten blijven zichtbaar."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Nu samenvatten")) {
                    open = false
                    guard let id = store.selection else { return }
                    Task { await chat.compact(id, store: store, baseURL: engine.baseURL) }
                }
                .disabled(store.selection.map(chat.isBusy) ?? true || chat.compacting || !engine.state.isRunning)
            }
            .padding(14).frame(width: 300)
        }
        .help(L("Context van het model in dit gesprek"))
    }
}

/// Opens a conversation at its last message and keeps the end in view as it grows. A scrollTo when the view appears
/// runs during the pane transition, while the lazy stack only has estimated heights, and lands in the middle of a long
/// conversation; the scroll anchor does not. A short conversation still starts at the top (macOS 15 and later).
private struct OpenAtEnd: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset).defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// This chat's folder, always visible: click to open it in the Finder.
private struct WorkspaceChip: View {
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        if settings.workspaceTools, let id = store.selection, let folder = store.conversations.first(where: { $0.id == id })?.workspace {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.amber)
                    Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                }
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Werkmap van dit gesprek: klik om hem in de Finder te openen"))
        }
    }
}

/// Model chip and a live speed line while the model writes.
private struct LiveStrip: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var metrics: LiveMetrics
    @EnvironmentObject var chat: ChatClient

    var body: some View {
        HStack(spacing: 12) {
            let m = engine.model ?? app.selectedModel
            HStack(spacing: 6) {
                Circle().fill(Theme.familyGradient(m?.family ?? "deepseek")).frame(width: 9, height: 9)
                Text(m?.name ?? L("Geen model")).font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            WorkspaceChip()
            Spacer()
            ContextMeter()
            if chat.busy || (metrics.current?.tokensPerSec ?? 0) > 0 {
                Sparkline(values: metrics.samples.suffix(60).map(\.tokensPerSec))
                    .frame(width: 160, height: 22)
                Text(String(format: "%.1f tok/s", metrics.current?.tokensPerSec ?? 0))
                    .font(.system(.callout, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.cool)
                    .contentTransition(.numericText()).animation(.snappy, value: metrics.current?.tokensPerSec ?? 0)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .animation(.easeInOut, value: chat.busy)
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { i, v in CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(v / maxV))) }
            ZStack {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                }
                .fill(LinearGradient(colors: [Theme.violet.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Theme.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: Theme.violet, radius: 3)
            }
        }
    }
}

private struct EmptyChat: View {
    @Binding var draft: String
    @EnvironmentObject var app: AppState
    private let suggestions = [
        ("globe", L("Wat is het laatste nieuws over Apple Silicon?")),
        ("chevron.left.forwardslash.chevron.right", L("Schrijf een Swift-functie die priemgetallen zoekt")),
        ("brain", L("Leg uit hoe een mixture-of-experts model werkt")),
        ("photo", L("Sleep een afbeelding hierheen en vraag wat erop staat")),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandMark(size: 84, active: false)
            Text(app.selectedModel?.name ?? L("MacAIMagic"))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
            Text(L("Volledig lokaal op je Mac. Niets verlaat je computer, behalve zoekopdrachten als je web zoeken aanzet."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(suggestions, id: \.1) { icon, text in
                    Button { draft = text } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).foregroundStyle(Theme.cyan).frame(width: 20)
                            Text(text).multilineTextAlignment(.leading).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 640)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EngineBanner: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    /// The second engine: the chat's model may run there already, as the fast model.
    @ObservedObject var fast: EngineController

    var body: some View {
        HStack {
            switch engine.state {
            case .starting(let s):
                ProgressView().controlSize(.small)
                // only a large model takes minutes; a small one is there in seconds
                let gb = Int((app.selectedModel?.files.reduce(UInt64(0)) { $0 + $1.size } ?? 0) / 1_000_000_000)
                Text(gb >= 50 ? L("\(s) Het eerste laden van \(gb) GB duurt enkele minuten.") : s)
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(e).lineLimit(2)
                Spacer()
                Button(L("Opnieuw")) { app.startEngine() }.disabled(!app.canStart)
            default:
                Image(systemName: "power").foregroundStyle(.secondary)
                Text(!app.canStart ? L("Het gekozen model staat er nog niet: kies of download er een bij Modellen.")
                     : app.chatModelOnFast.map { L("\($0.shortName) draait nu alleen als snel model, voor Documenten en Beeld. Start het om ermee te chatten; dan stopt het snelle exemplaar.") }
                     ?? L("Er is geen model gestart. Je vraag start het vanzelf, of klik op Start."))
                Spacer()
                Button(L("Start \(app.selectedModel?.shortName ?? L("model"))")) { app.startEngine() }.buttonStyle(.borderedProminent).disabled(!app.canStart)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }
}

// MARK: - message

struct MessageRow: View {
    let message: ChatMessage
    let streaming: Bool
    @State private var showThinking = false
    @State private var showAll = false

    /// A very long text as its start and its end, cut at line ends; nil when it is short enough to show whole.
    nonisolated static func folded(_ text: String, above: Int = 12_000, keep: Int = 4000) -> (head: String, hidden: Int, tail: String)? {
        guard text.count > above else { return nil }
        var head = String(text.prefix(keep))
        if let nl = head.lastIndex(of: "\n") { head = String(head[..<nl]) }
        var tail = String(text.suffix(keep))
        if let nl = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: nl)...]) }
        return (head, text.count - head.count - tail.count, tail)
    }

    var body: some View {
        if message.automatic == true && message.role == .user {
            Label(L("Het model was nog niet klaar en gaat automatisch door"), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        HStack {
                            ForEach(message.attachments) { a in
                                if let img = NSImage(data: a.jpeg) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                        .frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.15)))
                            .shadow(color: Theme.violet.opacity(0.35), radius: 12, y: 4)
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    PulseRing(active: streaming).frame(width: 30, height: 30)
                    BrandMark(size: 30, active: streaming)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if !message.reasoning.isEmpty {
                        DisclosureGroup(isExpanded: $showThinking) {
                            Text(message.reasoning.count > 12_000 ? "…\n" + String(message.reasoning.suffix(8000)) : message.reasoning)
                                .font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled).padding(.top, 4)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                        } label: {
                            Label(streaming && message.text.isEmpty ? L("Denkt na…") : L("Gedachtegang"),
                                  systemImage: "brain").font(.callout.weight(.medium))
                                .foregroundStyle(streaming && message.text.isEmpty ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                                .shimmer(streaming && message.text.isEmpty)
                        }
                    }
                    if !message.activities.isEmpty {
                        ActivityList(activities: message.activities, streaming: streaming)
                    }
                    if streaming, message.text.isEmpty, message.error == nil, let p = message.preparing {
                        // the model writes a tool call (a file, a command): say what, so the chat does not look idle
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(p).font(.callout).foregroundStyle(.secondary).shimmer(true)
                        }
                    } else if message.text.isEmpty && message.reasoning.isEmpty && streaming && message.error == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("Bezig…")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !showAll, let f = Self.folded(message.text) {
                        // a monologue of 100,000 characters is one view taller than macOS draws: the chat went blank
                        MarkdownText(text: f.head)
                        Button(L("… \(f.hidden.formatted()) tekens verborgen · Toon alles")) { showAll = true }
                            .buttonStyle(.link).font(.callout)
                        MarkdownText(text: f.tail)
                    } else {
                        MarkdownText(text: message.text)
                    }
                    if let e = message.error {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    }
                    if !message.sources.isEmpty { SourceChips(sources: message.sources) }
                    if let tps = message.tokensPerSecond, !streaming {
                        HStack(spacing: 10) {
                            Text(String(format: "%.1f tok/s", tps))
                            if let p = message.promptTokensPerSecond { Text(String(format: "prompt %.0f tok/s", p)) }
                            Button { copy(message.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
                            if Settings.shared.featureVoice {
                                SpeakButton(message: message)
                            }
                        }
                        .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
                .background(.ultraThinMaterial.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(streaming ? AnyShapeStyle(Theme.brand.opacity(0.6)) : AnyShapeStyle(.white.opacity(0.07))))
                Spacer(minLength: 0)
            }
        }
    }
}

/// The steps of an answer. While the model works the list grows, so you see every step as it comes (the last
/// dozen, with how many came before); when the answer is done it folds into one line, since the chat is about the
/// answer. A short list is simply shown.
struct ActivityList: View {
    let activities: [ToolActivity]
    let streaming: Bool
    @State private var open = false
    /// Up to this many steps are simply shown.
    private static let foldAbove = 3
    /// While working, at most this many of the latest steps.
    private static let live = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if activities.count <= Self.foldAbove {
                rows(activities)
            } else if streaming && !open {
                let hidden = activities.count - Self.live
                if hidden > 0 {
                    Button { open = true } label: {
                        Label(L("\(hidden) eerdere stappen"), systemImage: "list.bullet").font(.callout).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                rows(Array(activities.suffix(Self.live)))
            } else {
                DisclosureGroup(isExpanded: $open) {
                    rows(activities).padding(.top, 4)
                } label: {
                    Label(L("\(activities.count) stappen"), systemImage: "list.bullet").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rows(_ list: [ToolActivity]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list) { a in ActivityRow(activity: a) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SourceChips: View {
    let sources: [Source]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(sources.prefix(10)) { s in
                    if let url = URL(string: s.url) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                Text(url.host?.replacingOccurrences(of: "www.", with: "") ?? s.title).lineLimit(1)
                            }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                        }
                        .help(s.title)
                    }
                }
            }
        }
    }
}

/// Markdown with code blocks: fenced blocks get a monospaced card with a copy button, the rest inline markdown.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .code(let lang, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { copy(code) } label: { Label(L("Kopieer"), systemImage: "doc.on.doc").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        Divider()
                        ScrollView(.horizontal) {
                            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(10)
                        }
                    }
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
                case .heading(let level, let s):
                    Text(Self.inline(s)).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 4)
                case .text(let s):
                    Text(Self.inline(s)).textSelection(.enabled).lineSpacing(3)
                case .table(let header, let rows):
                    TableBlock(header: header, rows: rows)
                }
            }
        }
    }

    enum Block: Equatable { case text(String), code(String, String), heading(Int, String), table([String]?, [[String]]) }

    /// A Markdown table row: "| a | b |" → ["a", "b"]; nil for any other line.
    static func tableCells(_ line: String) -> [String]? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.count > 1, s.hasPrefix("|"), s.hasSuffix("|") else { return nil }
        return s.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The line under the header: |---|:--:|
    static func isSeparator(_ cells: [String]) -> Bool {
        cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } } && cells.contains { $0.contains("-") }
    }

    /// Rows of a table: the header (the row above the separator, unless it is empty) and the body without empty rows.
    static func table(_ lines: [[String]]) -> Block {
        var header: [String]?
        var rows = lines
        if let sep = rows.firstIndex(where: isSeparator) {
            if sep == 1 { header = rows[0]; rows.removeFirst(2) } else { rows.remove(at: sep) }
        }
        if header?.allSatisfy(\.isEmpty) == true { header = nil }
        return .table(header, rows.filter { !$0.allSatisfy(\.isEmpty) })
    }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        var lang = ""
        var rows: [[String]] = []
        func flush() {
            if !para.isEmpty { out.append(.text(para.joined(separator: "\n"))); para = [] }
            if !rows.isEmpty { out.append(table(rows)); rows = [] }
        }
        for line in s.components(separatedBy: "\n") {
            if code == nil, let cells = tableCells(line) {
                if !para.isEmpty { out.append(.text(para.joined(separator: "\n"))); para = [] }
                rows.append(cells)
                continue
            }
            if !rows.isEmpty { out.append(table(rows)); rows = [] }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code {
                    out.append(.code(lang, c.joined(separator: "\n"))); code = nil
                } else {
                    flush(); code = []
                    lang = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                }
            } else if code != nil {
                code!.append(line)
            } else if line.hasPrefix("#"), let sp = line.firstIndex(of: " "), line[..<sp].allSatisfy({ $0 == "#" }) {
                flush()
                out.append(.heading(line.distance(from: line.startIndex, to: sp), String(line[line.index(after: sp)...])))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                // markdown bullets read better as real bullets
                var l = line
                if let r = l.range(of: "^(\\s*)[-*] ", options: .regularExpression) {
                    l.replaceSubrange(r, with: String(l[r].dropLast(2)) + "• ")
                }
                para.append(l)
            }
        }
        if let c = code { out.append(.code(lang, c.joined(separator: "\n"))) }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// A Markdown table as a grid: the header bold, a line under it, columns as wide as they need.
struct TableBlock: View {
    let header: [String]?
    let rows: [[String]]
    private var columns: Int { max(header?.count ?? 0, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let header {
                    GridRow { cells(header, bold: true) }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { cells(row, bold: false) }
                }
            }
            .padding(10)
        }
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.18)))
        .textSelection(.enabled)
    }

    @ViewBuilder private func cells(_ row: [String], bold: Bool) -> some View {
        ForEach(0..<columns, id: \.self) { i in
            Text(MarkdownText.inline(i < row.count ? row[i] : "")).fontWeight(bold ? .semibold : nil)
        }
    }
}

/// Reads an answer aloud, or stops.
struct SpeakButton: View {
    let message: ChatMessage
    @ObservedObject private var voice = Voice.shared
    var body: some View {
        Button { voice.speak(message.text, id: message.id) } label: {
            Image(systemName: voice.speaking == message.id ? "speaker.slash.fill" : "speaker.wave.2")
        }
        .buttonStyle(.plain)
        .help(voice.speaking == message.id ? L("Stop met voorlezen") : L("Lees voor"))
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// One tool step; opens to show what the tool returned (command output, file listing, …).
struct ActivityRow: View {
    let activity: ToolActivity
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { if activity.output != nil { withAnimation(.snappy) { open.toggle() } } } label: {
                HStack(spacing: 6) {
                    if activity.denied == true { Image(systemName: "hand.raised.fill").foregroundStyle(Theme.amber) }
                    else if activity.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
                    else { ProgressView().controlSize(.mini) }
                    Text(activity.label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if activity.output != nil {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
            if open, let out = activity.output {
                ScrollView([.vertical, .horizontal]) {
                    Text(out).font(.caption.monospaced()).textSelection(.enabled).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

/// "May the model write this file / run this command?"
private struct ApprovalCard: View {
    let approval: ChatClient.Approval
    @EnvironmentObject var chat: ChatClient
    @State private var contentHeight: CGFloat = 0

    private struct ContentHeight: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var icon: String {
        if approval.call.name.hasPrefix("system_") { return approval.admin ? "lock.shield.fill" : "gearshape.2.fill" }
        if approval.call.name.contains("__") { return "puzzlepiece.extension.fill" }
        if let set = AgentTools.all.first(where: { $0.names.contains(approval.call.name) }) { return set.icon }
        return approval.call.name == "run_command" ? "terminal.fill" : "doc.badge.plus"
    }

    @ViewBuilder private var cardContent: some View {
        if approval.steps.isEmpty {
            Text(approval.detail).font(.callout.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(approval.steps.enumerated()), id: \.element.id) { i, step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(i + 1). \(step.title)" + (step.admin ? "  🔑" : "")).font(.callout.bold())
                        if let current = step.current {
                            Text(L("Nu: \(current)")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Text(step.command).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.amber)
                Text(approval.title).font(.system(.headline, design: .rounded))
                Spacer()
                if approval.admin {
                    Label(L("Beheerder"), systemImage: "key.fill").font(.caption.bold()).foregroundStyle(.orange)
                }
            }
            if !approval.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(approval.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            // as high as what it shows, and scrolling only from 160/240 points on
            ScrollView {
                cardContent.background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeight.self, value: g.size.height)
                })
            }
            .frame(height: min(max(contentHeight, 24), approval.steps.isEmpty ? 160 : 240))
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            if approval.admin {
                Toggle(L("Maak eerst een lokale snapshot (Time Machine), zodat je altijd terug kunt"), isOn: $chat.snapshot)
                    .font(.callout)
                Text(L("Na Toestaan vraagt macOS om je wachtwoord. MacAIMagic en het model zien dat wachtwoord niet."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("Weigeren"), role: .cancel) { chat.answer(approval, allow: false) }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                if !approval.admin && !approval.everyTime {
                    Button(L("Altijd in dit gesprek")) { chat.answer(approval, allow: true, always: true) }
                }
                Button { chat.answer(approval, allow: true) } label: { Label(L("Toestaan"), systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent).tint(approval.warnings.isEmpty ? Theme.amber : .red).keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke((approval.warnings.isEmpty ? Theme.amber : Color.red).opacity(0.6), lineWidth: 1.5))
        .shadow(color: Theme.amber.opacity(0.25), radius: 14)
        .frame(maxWidth: 860)
        .padding(.horizontal, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
