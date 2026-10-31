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

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        VStack(spacing: 0) {
            if let c = conversation, !c.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(c.messages.filter { !$0.isHidden }) { m in
                                MessageRow(message: m, streaming: chat.busy && m.id == c.messages.last?.id)
                                    .id(m.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: 820)
                        .padding(.horizontal, 24).padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: c.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: c.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onAppear { if scrollToEnd { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            } else {
                EmptyChat()
            }
            if !engine.state.isRunning { EngineBanner() }
            Composer(conversationID: conversationID)
        }
        .navigationTitle(conversation?.title ?? "MacDeepSeek")
    }
}

private struct EmptyChat: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 42)).foregroundStyle(Theme.accent)
            Text("DeepSeek-V4.1-Flash").font(.largeTitle.weight(.semibold))
            Text("748 miljard parameters, volledig lokaal op je Mac. Niets verlaat je computer, behalve zoekopdrachten als je web zoeken aanzet.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Spacer()
        }
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
        .background(.bar)
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
                        Text(message.text).textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(.white).font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28).background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 10) {
                    if !message.reasoning.isEmpty {
                        DisclosureGroup(isExpanded: $showThinking) {
                            Text(message.reasoning).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled).padding(.top, 4)
                                .padding(.leading, 10)
                                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                        } label: {
                            Label(streaming && message.text.isEmpty ? "Denkt na…" : "Gedachtegang",
                                  systemImage: "brain").font(.callout).foregroundStyle(.secondary)
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
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
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
