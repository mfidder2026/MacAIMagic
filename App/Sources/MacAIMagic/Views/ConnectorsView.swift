import SwiftUI

/// Instellingen → Connectors: the MCP servers the model may use, each with its own right.
struct ConnectorsView: View {
    @ObservedObject var mcp = MCPManager.shared
    @State private var editing: MCPServerConfig?
    @State private var isNew = false
    @State private var showLog: String?
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(L("Connectors geven het model gereedschap van andere programma's en diensten (MCP). Het laadt een connector pas als het hem nodig heeft. Tools die alleen lezen mogen standaard; voor de rest kies je per connector."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HelpButton(topic: "connectors")
                }
                HStack {
                    Menu(L("Voorbeeld toevoegen")) {
                        ForEach(ConnectorPresets.all, id: \.name) { p in
                            Button(p.name) { addPreset(p) }.disabled(mcp.config(p.name) != nil)
                        }
                    }
                    .fixedSize()
                    Button(L("Toevoegen…")) { isNew = true; editing = MCPServerConfig(name: "", command: "", right: "ask") }
                    Button(L("Importeer")) { importOthers() }
                        .help(L("Neemt connectors over uit Claude Desktop en Claude Code; ze komen uitgeschakeld binnen."))
                }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }
            Section(L("Connectors")) {
                if mcp.servers.isEmpty {
                    Text(L("Nog geen connectors. Begin met een voorbeeld, zoals Agenda en Herinneringen.")).foregroundStyle(.secondary)
                }
                ForEach(mcp.servers) { s in row(s) }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { c in
            ConnectorEditor(original: isNew ? nil : c.name, config: c) { editing = nil; isNew = false }
        }
        .sheet(item: Binding(get: { showLog.map { LogItem(name: $0) } }, set: { showLog = $0?.name })) { item in
            VStack(alignment: .leading) {
                Text(L("Log van \(item.name)")).font(.headline)
                ScrollView { Text(mcp.logs[item.name] ?? L("(leeg)")).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button(L("Sluiten")) { showLog = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(16).frame(width: 520, height: 380)
        }
    }

    private struct LogItem: Identifiable { let name: String; var id: String { name } }

    @ViewBuilder private func row(_ s: MCPServerConfig) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { s.isEnabled }, set: { on in var c = s; c.enabled = on; mcp.upsert(c) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(color(mcp.states[s.name])).frame(width: 7, height: 7)
                    Text(s.name).font(.body.weight(.medium))
                    if s.isRemote { Image(systemName: "globe").font(.caption).foregroundStyle(.secondary) }
                    if s.builtin != nil { Image(systemName: "apple.logo").font(.caption).foregroundStyle(.secondary) }
                }
                Text(status(s)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Picker("", selection: Binding(get: { s.rightValue }, set: { r in var c = s; c.right = r; mcp.upsert(c) })) {
                Text(L("Toestaan")).tag("allow"); Text(L("Eerst vragen")).tag("ask"); Text(L("Weigeren")).tag("deny")
            }
            .labelsHidden().fixedSize()
            Menu {
                Button(L("Test verbinding")) { Task { await test(s) } }
                Button(L("Bewerken…")) { isNew = false; editing = s }
                Button(L("Log")) { showLog = s.name }
                if s.isRemote, s.oauth != false, let u = s.url.flatMap(URL.init(string:)) {
                    Button(L("Uitloggen")) { Task { await MCPOAuth.shared.logOut(u); mcp.stop(s.name) } }
                }
                Divider()
                Button(L("Verwijderen"), role: .destructive) { mcp.remove(s.name) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func color(_ s: MCPManager.State?) -> Color {
        switch s {
        case .ready?: return .green
        case .starting?: return .yellow
        case .failed?: return .red
        default: return .gray.opacity(0.5)
        }
    }

    private func status(_ s: MCPServerConfig) -> String {
        let what = s.description ?? (s.url ?? ([s.command ?? ""] + (s.args ?? [])).joined(separator: " "))
        switch mcp.states[s.name] {
        case .ready(let n)?: return L("Actief, \(n) tools") + " · " + what
        case .starting?: return L("Starten…")
        case .failed(let why)?: return L("Fout: \(why)")
        default: return what
        }
    }

    private func test(_ s: MCPServerConfig) async {
        notice = L("\(s.name) testen…")
        switch await mcp.test(s) {
        case .success(let tools): notice = L("\(s.name) werkt: \(tools.count) tools (\(tools.prefix(6).map(\.name).joined(separator: ", "))).")
        case .failure(let e): notice = L("\(s.name) werkt niet: \(e.localizedDescription)")
        }
    }

    private func addPreset(_ p: ConnectorPresets.Preset) {
        if let missing = p.needs, !ConnectorPresets.hasTool(missing) {
            notice = L("Voor \(p.name) is \(missing) nodig. Installeer het eerst, bijvoorbeeld met: \(ConnectorPresets.install(missing))")
            return
        }
        if p.askToken {
            isNew = true
            editing = p.config
        } else {
            mcp.upsert(p.config)
            notice = L("\(p.name) is toegevoegd en staat aan.")
        }
    }

    private func importOthers() {
        let found = mcp.importable()
        for c in found { mcp.upsert(c) }
        notice = found.isEmpty ? L("Geen nieuwe connectors gevonden in Claude Desktop of Claude Code.")
            : L("\(found.count) connector(s) overgenomen, uitgeschakeld: \(found.map(\.name).joined(separator: ", ")).")
    }
}

/// Add or change one connector.
struct ConnectorEditor: View {
    let original: String?
    @State var config: MCPServerConfig
    var done: () -> Void
    @State private var kind = 0
    @State private var argsText = ""
    @State private var envText = ""
    @State private var token = ""
    @State private var result: String?

    init(original: String?, config: MCPServerConfig, done: @escaping () -> Void) {
        self.original = original
        self.done = done
        _config = State(initialValue: config)
        _kind = State(initialValue: config.builtin != nil ? 2 : config.url != nil ? 1 : 0)
        _argsText = State(initialValue: (config.args ?? []).joined(separator: "\n"))
        _envText = State(initialValue: (config.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(original == nil ? L("Connector toevoegen") : L("Connector bewerken")).font(.headline)
            Form {
                TextField(L("Naam"), text: $config.name)
                TextField(L("Waarvoor (één regel voor het model)"), text: Binding(get: { config.description ?? "" }, set: { config.description = $0.isEmpty ? nil : $0 }))
                if config.builtin == nil {
                    Picker(L("Soort"), selection: $kind) {
                        Text(L("Programma op deze Mac")).tag(0)
                        Text(L("Internetadres")).tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                if kind == 0 && config.builtin == nil {
                    TextField(L("Commando, bijvoorbeeld npx"), text: Binding(get: { config.command ?? "" }, set: { config.command = $0 }))
                    TextField(L("Argumenten, één per regel"), text: $argsText, axis: .vertical).lineLimit(2...6).font(.callout.monospaced())
                    TextField(L("Omgeving, NAAM=waarde per regel"), text: $envText, axis: .vertical).lineLimit(1...4).font(.callout.monospaced())
                } else if kind == 1 {
                    TextField(L("Adres (URL)"), text: Binding(get: { config.url ?? "" }, set: { config.url = $0 }))
                    Toggle(L("Inloggen in de browser als de dienst daarom vraagt (OAuth)"), isOn: Binding(get: { config.oauth ?? true }, set: { config.oauth = $0 }))
                    SecureField(L("Token (optioneel, komt in de Keychain)"), text: $token)
                    Text(L("Wat je met deze connector deelt, gaat naar die dienst op internet.")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L("Ingebouwd in MacAIMagic: er draait geen programma van een ander.")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(L("Altijd geladen (tools staan in elk gesprek klaar; kost leestijd)"), isOn: Binding(get: { config.alwaysLoaded ?? false }, set: { config.alwaysLoaded = $0 }))
            }
            .formStyle(.grouped)
            if let result { Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                Button(L("Test verbinding")) { Task { result = L("Testen…"); let r = await MCPManager.shared.test(built()); result = describe(r) } }
                Spacer()
                Button(L("Annuleren"), role: .cancel) { done() }
                Button(L("Bewaar")) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    private func describe(_ r: Result<[MCPTool], Error>) -> String {
        switch r {
        case .success(let t): return L("Werkt: \(t.count) tools (\(t.prefix(6).map(\.name).joined(separator: ", "))).")
        case .failure(let e): return L("Werkt niet: \(e.localizedDescription)")
        }
    }

    private func built() -> MCPServerConfig {
        var c = config
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if c.builtin != nil { return c }
        if kind == 0 {
            c.url = nil; c.headers = nil; c.oauth = nil
            c.args = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var env: [String: String] = [:]
            for line in envText.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1] }
            }
            c.env = env.isEmpty ? nil : env
        } else {
            c.command = nil; c.args = nil; c.env = nil
            if !token.isEmpty {
                let account = "mcp-" + c.name
                MCPKeychain.set(token.hasPrefix("Bearer ") ? token : "Bearer " + token, for: account)
                var h = c.headers ?? [:]
                h["Authorization"] = "keychain:" + account
                c.headers = h
            }
        }
        return c
    }

    private func save() {
        MCPManager.shared.upsert(built(), replacing: original)
        done()
    }
}

/// The connectors that come ready to switch on.
enum ConnectorPresets {
    struct Preset {
        let name: String
        let config: MCPServerConfig
        /// A program that must be on the Mac (npx, uvx).
        var needs: String? = nil
        /// Opens the editor for a token first.
        var askToken = false
    }

    static var all: [Preset] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var files = MCPServerConfig(name: L("Bestanden"), command: "npx",
                                    args: ["-y", "@modelcontextprotocol/server-filesystem", home + "/Documents", home + "/Downloads", home + "/Desktop"],
                                    right: "ask", description: L("Bestanden lezen, zoeken en schrijven in Documenten, Downloads en Bureaublad"))
        files.enabled = true
        var fetch = MCPServerConfig(name: L("Web ophalen"), command: "uvx", args: ["mcp-server-fetch"], right: "ask",
                                    description: L("Een webpagina ophalen als tekst"))
        fetch.enabled = true
        var github = MCPServerConfig(name: "GitHub", url: "https://api.githubcopilot.com/mcp/", right: "ask",
                                     description: L("Repositories, issues en pull requests op GitHub"))
        github.oauth = false
        github.enabled = true
        var calendar = MCPServerConfig(name: L("Agenda en Herinneringen"), right: "ask",
                                       description: L("Afspraken en herinneringen van deze Mac tonen, maken en afvinken"))
        calendar.builtin = "calendar"
        calendar.enabled = true
        return [
            Preset(name: calendar.name, config: calendar),
            Preset(name: files.name, config: files, needs: "npx"),
            Preset(name: fetch.name, config: fetch, needs: "uvx"),
            Preset(name: github.name, config: github, askToken: true),
        ]
    }

    static func hasTool(_ name: String) -> Bool {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin"]
            .contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }

    static func install(_ tool: String) -> String { tool == "uvx" ? "brew install uv" : "brew install node" }
}
