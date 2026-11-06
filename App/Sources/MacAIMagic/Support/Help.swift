import SwiftUI

/// One page of the help: help/<language>/<NN-id>.md, with front matter (title, icon, keywords).
struct HelpTopic: Identifiable, Hashable {
    var id: String
    var title: String
    var icon: String
    var keywords: String
    var body: String
}

/// The help in the app: Dutch, or English for every other language. Opened from the sidebar, with the ? at the top
/// right of every page (the help for that page), and with ⌘? from the Help menu.
@MainActor
final class HelpCenter: ObservableObject {
    static let shared = HelpCenter()
    /// The topic to show; set by a ? button, read by the help page.
    @Published var selected: String = "start"
    /// Bumped when something asks to open the help, so the window switches to it.
    @Published var openRequest = 0

    func open(_ topic: String) {
        selected = topic
        openRequest += 1
    }

    /// The help's language: Dutch for Dutch, English for the others.
    nonisolated static var language: String { AppLanguage.current == .nl ? "nl" : "en" }

    nonisolated static func folder(_ language: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Help/\(language)")) }
        candidates.append(contentsOf: Paths.sourceFolders("help/\(language)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func topics(_ language: String = language) -> [HelpTopic] {
        guard let folder = folder(language),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            // 03-workspace.md → workspace
            let id = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1).last.map(String.init) ?? ""
            return parse(text, id: id)
        }
    }

    nonisolated static func parse(_ text: String, id: String) -> HelpTopic? {
        guard let skill = Skills.parse(text, fallbackName: id) else { return nil }
        // the same front matter as a skill; keywords and icon are read here
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: "\n").prefix(12) {
            if let c = line.firstIndex(of: ":") {
                fields[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return HelpTopic(id: id, title: fields["title"] ?? skill.name, icon: fields["icon"] ?? "questionmark.circle",
                         keywords: fields["keywords"] ?? "", body: skill.body)
    }

    /// Topics whose title, keywords or text contain every word of the query, best first: a word in the title counts
    /// most, then in the keywords, then how often it is in the text.
    nonisolated static func search(_ query: String, in topics: [HelpTopic]) -> [HelpTopic] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return topics }
        func score(_ t: HelpTopic) -> Int? {
            let title = t.title.lowercased(), keys = t.keywords.lowercased(), body = t.body.lowercased()
            var total = 0
            for w in words {
                let inBody = body.components(separatedBy: w).count - 1
                guard title.contains(w) || keys.contains(w) || inBody > 0 else { return nil }
                total += (title.contains(w) ? 20 : 0) + (keys.contains(w) ? 8 : 0) + min(inBody, 10)
            }
            return total
        }
        return topics.compactMap { t in score(t).map { (t, $0) } }
            .enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
    }

    /// The help topic for a page of the app.
    static func topic(for pane: Pane?) -> String {
        switch pane {
        case .live?: "live"
        case .models?, nil: "models"
        case .documents?: "documents"
        case .images?: "images"
        case .compare?: "compare"
        case .cluster?: "cluster"
        case .system?: "system"
        case .help?: "start"
        case .chat?: "chat"
        }
    }
}

/// A small ? that opens the help at a topic.
struct HelpButton: View {
    let topic: String
    var body: some View {
        Button { HelpCenter.shared.open(topic) } label: { Image(systemName: "questionmark.circle") }
            .buttonStyle(.borderless).help(L("Hulp bij dit onderdeel"))
            .accessibilityLabel(L("Hulp bij dit onderdeel"))
    }
}

struct HelpView: View {
    @ObservedObject var center = HelpCenter.shared
    @State private var query = ""
    @State private var topics: [HelpTopic] = HelpCenter.topics()

    private var shown: [HelpTopic] { HelpCenter.search(query, in: topics) }
    private var current: HelpTopic? { topics.first { $0.id == center.selected } ?? topics.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill").font(.title2).foregroundStyle(Theme.brand)
                    Text(L("Hulp")).font(.system(size: 26, weight: .bold, design: .rounded))
                }
                .padding(.bottom, 4)
                TextField(L("Zoek in de hulp…"), text: $query).textFieldStyle(.roundedBorder)
                List(shown, selection: Binding(get: { center.selected }, set: { if let v = $0 { center.selected = v } })) { t in
                    Label(t.title, systemImage: t.icon).lineLimit(2).tag(t.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                if shown.isEmpty {
                    Text(L("Niets gevonden. Probeer een ander woord.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(width: 310)
            Divider()
            ScrollView {
                if let t = current {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(t.title, systemImage: t.icon).font(.system(size: 28, weight: .bold, design: .rounded))
                        HelpBody(text: t.body, query: query)
                    }
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                } else {
                    Text(L("De hulpteksten ontbreken in deze versie van de app.")).padding(28)
                }
            }
        }
        .onChange(of: query) { _, q in
            // the best hit opens by itself
            if !q.trimmingCharacters(in: .whitespaces).isEmpty, let first = HelpCenter.search(q, in: topics).first {
                center.selected = first.id
            }
        }
        .onAppear { topics = HelpCenter.topics() }
    }
}

/// Help markdown: ## headings, lists, tables shown as lines, and the rest as chat markdown (code blocks with copy).
struct HelpBody: View {
    let text: String
    var query = ""

    enum Block: Hashable { case heading(String), text(String), tip(String) }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var buffer: [String] = []
        var inCode = false
        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.text(t)) }
            buffer = []
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inCode.toggle(); buffer.append(line); continue }
            if !inCode, line.hasPrefix("## ") || line.hasPrefix("### ") {
                flush(); out.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if !inCode, line.hasPrefix("> ") {
                flush(); out.append(.tip(String(line.dropFirst(2))))
            } else if !inCode, line.hasPrefix("|") {
                // a table becomes one line per row: "a — b — c"; the line under the header is dropped
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { buffer.append("• " + cells.joined(separator: " — ")) }
            } else if !inCode, line.hasPrefix("- ") {
                buffer.append("• " + line.dropFirst(2))
            } else {
                buffer.append(line)
            }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let h):
                    Text(h).font(.system(.title3, design: .rounded).bold()).padding(.top, 6)
                case .tip(let t):
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(Theme.amber)
                        MarkdownText(text: t)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                case .text(let t):
                    MarkdownText(text: t)
                }
            }
        }
    }
}
