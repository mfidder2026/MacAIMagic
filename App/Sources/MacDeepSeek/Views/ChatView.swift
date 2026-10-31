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
                                MessageRow(message: m, streaming: chat.busy && m.id == c.messages.last?.id)
                                    .id(m.id)
                                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: c.messages.count)
                        .frame(maxWidth: 860)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: c.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: c.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onAppear { if scrollToEnd { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            } else {
                EmptyChat(draft: $draft)
            }
            if !engine.state.isRunning { EngineBanner() }
            Composer(conversationID: conversationID, text: $draft)
        }
        .navigationTitle(conversation?.title ?? "MacDeepSeek")
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
                Text(m?.name ?? "Geen model").font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
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
        ("globe", "Wat is het laatste nieuws over Apple Silicon?"),
        ("chevron.left.forwardslash.chevron.right", "Schrijf een Swift-functie die priemgetallen zoekt"),
        ("brain", "Leg uit hoe een mixture-of-experts model werkt"),
        ("photo", "Sleep een afbeelding hierheen en vraag wat erop staat"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandMark(size: 84, active: true)
            Text(app.selectedModel?.name ?? "MacDeepSeek")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brand)
            Text("Volledig lokaal op je Mac. Niets verlaat je computer, behalve zoekopdrachten als je web zoeken aanzet.")
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

    var body: some View {
        HStack {
            switch engine.state {
            case .starting(let s):
                ProgressView().controlSize(.small)
                Text("\(s) Het eerste laden van 115 GB duurt enkele minuten.")
            case .failed(let e):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(e).lineLimit(2)
                Spacer()
                Button("Opnieuw") { app.startEngine() }.disabled(!app.canStart)
            default:
                Image(systemName: "power").foregroundStyle(.secondary)
                Text(app.canStart ? "De engine staat uit." : "Model of engine nog niet klaar: zie Engine & model.")
                Spacer()
                Button("Start engine") { app.startEngine() }.buttonStyle(.borderedProminent).disabled(!app.canStart)
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

    var body: some View {
        if message.role == .user {
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
                            Text(message.reasoning).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled).padding(.top, 4)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                        } label: {
                            Label(streaming && message.text.isEmpty ? "Denkt na…" : "Gedachtegang",
                                  systemImage: "brain").font(.callout.weight(.medium))
                                .foregroundStyle(streaming && message.text.isEmpty ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary))
                                .shimmer(streaming && message.text.isEmpty)
                        }
                    }
                    if !message.activities.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(message.activities) { a in
                                HStack(spacing: 6) {
                                    if a.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                    else { ProgressView().controlSize(.mini) }
                                    Text(a.label).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    if message.text.isEmpty && message.reasoning.isEmpty && streaming && message.error == nil {
                        ProgressView().controlSize(.small)
                    }
                    MarkdownText(text: message.text)
                    if let e = message.error {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    }
                    if !message.sources.isEmpty { SourceChips(sources: message.sources) }
                    if let tps = message.tokensPerSecond, !streaming {
                        HStack(spacing: 10) {
                            Text(String(format: "%.1f tok/s", tps))
                            if let p = message.promptTokensPerSecond { Text(String(format: "prompt %.0f tok/s", p)) }
                            Button { copy(message.text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain)
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
                            Button { copy(code) } label: { Label("Kopieer", systemImage: "doc.on.doc").font(.caption) }
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
                }
            }
        }
    }

    enum Block { case text(String), code(String, String), heading(Int, String) }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        var lang = ""
        func flush() {
            if !para.isEmpty { out.append(.text(para.joined(separator: "\n"))); para = [] }
        }
        for line in s.components(separatedBy: "\n") {
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

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
