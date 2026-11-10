import Foundation

/// The app as the model sees it: its state for app_status, and the actions of app_action, done the way the buttons do
/// them. Actions that would stop the engine this conversation runs on wait until its answer is done.
@MainActor
final class AppControl: AppControlling {
    private unowned let app: AppState
    /// What waits for a conversation's answer to be done.
    private var afterAnswer: [UUID: [() async -> Void]] = [:]

    init(app: AppState) { self.app = app }

    // MARK: - settings the model may change

    /// One setting: its value now, the values it takes (nil: free text or a number), and how to set it.
    struct Setting {
        let get: () -> String
        let options: [String]?
        let kind: String
        let set: (String) -> Bool
    }

    private static func bool(_ v: String) -> Bool? {
        switch v.lowercased() {
        case "true", "1", "on", "aan", "ja", "yes": return true
        case "false", "0", "off", "uit", "nee", "no": return false
        default: return nil
        }
    }

    private static func flag(_ key: ReferenceWritableKeyPath<Settings, Bool>) -> Setting {
        Setting(get: { String(Settings.shared[keyPath: key]) }, options: nil, kind: "true/false") { v in
            guard let b = bool(v) else { return false }
            Settings.shared[keyPath: key] = b
            return true
        }
    }

    private static func choice(_ key: ReferenceWritableKeyPath<Settings, String>, _ options: [String]) -> Setting {
        Setting(get: { Settings.shared[keyPath: key] }, options: options, kind: options.joined(separator: "/")) { v in
            guard let o = options.first(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) else { return false }
            Settings.shared[keyPath: key] = o
            return true
        }
    }

    private static func number(_ key: ReferenceWritableKeyPath<Settings, Int>, _ options: [Int]) -> Setting {
        Setting(get: { String(Settings.shared[keyPath: key]) }, options: options.map(String.init), kind: options.map(String.init).joined(separator: "/")) { v in
            guard let n = Int(v), options.contains(n) else { return false }
            Settings.shared[keyPath: key] = n
            return true
        }
    }

    /// Not here: its own rights, API keys, the server address and port, the model folder, the cluster settings (those
    /// go through the cluster actions).
    static let settings: [(name: String, setting: Setting)] = [
        ("language", choice(\.language, ["nl", "en", "de", "fr"])),
        ("contextSize", number(\.contextSize, [32_768, 65_536, 131_072, 262_144, 524_288, 1_048_576])),
        ("vision", flag(\.vision)),
        ("thinking", flag(\.thinking)),
        ("reasoningEffort", choice(\.reasoningEffort, ["low", "medium", "high", "max"])),
        ("thinkingBudget", number(\.thinkingBudget, [0, 4_000, 8_000, 16_000, 32_000])),
        ("temperature", Setting(get: { String(format: "%.1f", Settings.shared.temperature) }, options: nil, kind: "0-1.5") { v in
            guard let d = Double(v.replacingOccurrences(of: ",", with: ".")), (0...1.5).contains(d) else { return false }
            Settings.shared.temperature = d
            return true
        }),
        ("systemPrompt", Setting(get: { Settings.shared.systemPrompt }, options: nil, kind: "text") { v in Settings.shared.systemPrompt = v; return true }),
        ("webSearch", flag(\.webSearch)),
        ("mtp", flag(\.mtp)),
        ("ngramMod", flag(\.ngramMod)),
        ("autoStart", flag(\.autoStart)),
        ("animatedBackground", flag(\.animatedBackground)),
        ("workspaceTools", flag(\.workspaceTools)),
        ("learnFromChats", flag(\.learnFromChats)),
        ("imageImprove", flag(\.imageImprove)),
        ("imageSize", choice(\.imageSize, [""] + ImagePlanner.sizes.map(\.key))),
        ("skills", flag(\.skills)),
        ("systemManagement", flag(\.systemManagement)),
        ("heartbeat", flag(\.heartbeat)),
        ("heartbeatMinutes", number(\.heartbeatMinutes, [30, 60, 120, 240])),
        ("tasksStopModel", flag(\.tasksStopModel)),
        ("stayInMenuBar", flag(\.stayInMenuBar)),
        ("featureTelegram", flag(\.featureTelegram)),
        ("featureMail", flag(\.featureMail)),
        ("featureBrowser", flag(\.featureBrowser)),
        ("featureComputerUse", flag(\.featureComputerUse)),
        ("featureVoice", flag(\.featureVoice)),
        ("speakAnswers", flag(\.speakAnswers)),
        ("telegramNotify", flag(\.telegramNotify)),
    ]

    static func setting(_ name: String) -> (name: String, setting: Setting)? {
        settings.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var settingNames: [String] { Self.settings.map { "\($0.name) (\($0.setting.kind))" } }

    // MARK: - status

    func status() -> String {
        let s = app.system
        var o: [String] = []
        o.append("MacAIMagic \(Paths.appVersion ?? "(from source)"), language \(Settings.shared.language).")
        o.append("This Mac: \(s.chip), \(s.physicalMemory >> 30) GB memory (GPU may keep \(s.gpuWorkingSet >> 30) GB resident), \(s.freeDisk / 1_000_000_000) GB free on disk.")
        let running = app.engine.model.map { ", running \($0.id)" } ?? ""
        o.append("Engine: \(app.engine.state)\(running); heavy model chosen: \(app.selectedModelID)\(app.canStart || app.engine.state.isRunning ? "" : " (cannot start now)").")
        let fast = app.documentEngines.fast
        o.append("Fast model (Snel): \(Settings.shared.fastModel.isEmpty ? "chosen by the app" : Settings.shared.fastModel)\(fast.state.isRunning ? ", running \(fast.model?.id ?? "")" : ""). Image model: \(app.imageModel?.id ?? "none")\(app.images.busy ? ", making an image now" : "").")
        o.append("")
        o.append("Models (id: name, size, on this Mac, downloaded):")
        let recommended = SystemCheck.recommended(app.models.catalog.models, physical: s.physicalMemory)?.id
        for m in app.models.catalog.models + app.models.catalog.images {
            let st = app.models.status(m.id)
            let image = app.models.catalog.images.contains(m)
            let fit = image ? "makes images" : {
                switch MemoryPlanner.fit(m, physical: s.physicalMemory) {
                case .fits: return "fits in memory"
                case .streams: return "streams from the SSD"
                case .tooBig: return "too big for this Mac"
                }
            }()
            let gb = { (b: UInt64) in String(format: "%.1f GB", Double(b) / 1e9) }
            let state = st.isComplete ? (st.updateAvailable ? "downloaded, an update is available" : "downloaded")
                : app.models.downloading.contains(m.id) ? "downloading, \(gb(st.have)) of \(gb(st.expected))"
                : st.have > 0 ? "partly downloaded (\(gb(st.have)) of \(gb(st.expected)))" : "not downloaded"
            o.append("- \(m.id): \(m.name), \(gb(m.totalSize)), \(fit), \(state)\(m.id == recommended ? ", RECOMMENDED for this Mac" : "")")
        }
        o.append("")
        o.append("Settings the model may change with set_setting (name = value):")
        for (name, setting) in Self.settings {
            var value = setting.get()
            if name == "systemPrompt" { value = value.isEmpty ? "(empty)" : String(value.prefix(80)) }
            o.append("- \(name) = \(value) (\(setting.kind))")
        }
        o.append("")
        let c = app.cluster
        o.append("Cluster: this Mac is \(c.role == .helper ? "a helper" : "the main Mac"); local network \(Settings.shared.clusterAllowLAN ? "allowed" : "not allowed (Thunderbolt cable only)"); addresses: \(ClusterController.addresses().map { "\($0.interface) \($0.ip)" }.joined(separator: ", ")).")
        if c.role == .helper {
            o.append(c.helperRunning ? "Helper running on \(c.helperAddress)." : "Helper not running (start_helper).")
        } else {
            if c.helpers.isEmpty { o.append("No helpers found. A helper is another Mac with MacAIMagic (or a PC with WinAIMagic) in the role helper and its helper started.") }
            for h in c.helpers {
                o.append("- helper \(h.id): \(h.name), \(h.chip), \(String(format: "%.1f", h.gpuGB)) GB for the model\(h.memoryGB > 0 ? ", \(Int(h.memoryGB)) GB memory" : ""), \(h.viaThunderbolt ? "Thunderbolt cable" : "network")\(h.manual ? ", added by hand" : "")\(h.unreachable ? ", NOT REACHABLE on its port" : "")\(c.selected.contains(h.id) ? ", in use" : ", not in use")")
            }
        }
        let st = Settings.shared
        o.append("Rights (only the user changes these, in Settings): work folder read \(st.rightRead), write \(st.rightWrite), run \(st.rightRun); system read \(st.rightSystemRead), change \(st.rightSystemChange).")
        o.append("Tasks: \(app.tasks.tasks.count) (\(app.tasks.tasks.filter(\.enabled).count) on); heartbeat \(st.heartbeat ? "on" : "off").")
        o.append("Model folder: \(Paths.modelsRoot.path). Own skills: \(Paths.userSkills.path).")
        o.append("Local API: http://\(st.host):\(st.port)/v1 (OpenAI) and /v1/messages (Anthropic)\(st.apiKey.isEmpty ? "" : ", with an API key").")
        return o.joined(separator: "\n")
    }

    // MARK: - actions

    private func arg(_ a: [String: Any], _ key: String) -> String {
        let v = a[key]
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let b = v as? Bool { return b ? "true" : "false" }
        return v.map { "\($0)" }?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func model(_ a: [String: Any]) -> ModelInfo? {
        let id = arg(a, "model")
        return (app.models.catalog.models + app.models.catalog.images).first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    private func noModel(_ a: [String: Any]) -> String {
        "There is no model \"\(arg(a, "model"))\". Ids: " + (app.models.catalog.models + app.models.catalog.images).map(\.id).joined(separator: ", ") + "."
    }

    static let pages: [String: Pane] = [
        "live": .live, "models": .models, "modellen": .models, "documents": .documents, "documenten": .documents,
        "images": .images, "beeld": .images, "tasks": .tasks, "taken": .tasks, "cluster": .cluster,
        "compare": .compare, "vergelijken": .compare, "system": .system, "systeem": .system, "help": .help, "hulp": .help,
    ]

    private var engineRuns: Bool {
        switch app.engine.state {
        case .running, .starting: return true
        default: return false
        }
    }

    private func inUse(_ m: ModelInfo) -> Bool {
        if app.models.catalog.images.contains(m) { return app.images.busy }
        return (engineRuns && app.engine.model?.id == m.id) || (app.documentEngines.fast.state.isRunning && app.documentEngines.fast.model?.id == m.id)
    }

    private func helper(_ a: [String: Any]) -> ClusterController.Helper? {
        let wanted = arg(a, "helper")
        return app.cluster.helpers.first { $0.id.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    private func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }

    func plan(_ action: String, _ a: [String: Any]) -> AppActionPlan {
        let store = app.models
        switch action {
        case "open_page":
            let page = arg(a, "page").lowercased()
            return page == "chat" || Self.pages[page] != nil ? AppActionPlan(readOnly: true)
                : AppActionPlan(error: "Unknown page. Pages: chat, live, models, documents, images, tasks, cluster, compare, system, help.")
        case "open_help", "find_helpers":
            return AppActionPlan(readOnly: true)
        case "new_conversation":
            return AppActionPlan(afterAnswer: true, readOnly: true)
        case "download_model":
            guard let m = model(a) else { return AppActionPlan(error: noModel(a)) }
            let st = store.status(m.id)
            if st.isComplete && !st.updateAvailable { return AppActionPlan(error: "\(m.name) is downloaded already.") }
            if store.downloading.contains(m.id) { return AppActionPlan(error: "\(m.name) is downloading already.") }
            let left = st.updateAvailable ? st.updateBytes : st.expected - min(st.have, st.expected)
            return AppActionPlan(title: L("\(m.name) downloaden (\(gb(left > 0 ? left : m.totalSize)))"),
                                 detail: L("Er is \(gb(app.system.freeDisk)) vrij op de schijf."))
        case "pause_download":
            guard let m = model(a), store.downloading.contains(m.id) else { return AppActionPlan(error: "That model is not downloading.") }
            return AppActionPlan(title: L("Download van \(m.name) pauzeren"))
        case "check_update":
            guard let m = model(a) else { return AppActionPlan(error: noModel(a)) }
            return store.status(m.id).isComplete ? AppActionPlan(readOnly: true) : AppActionPlan(error: "\(m.name) is not downloaded.")
        case "delete_model":
            guard let m = model(a) else { return AppActionPlan(error: noModel(a)) }
            if inUse(m) { return AppActionPlan(error: "\(m.name) is in use. Stop it first (stop_engine, after this answer).") }
            return AppActionPlan(title: L("\(m.name) verwijderen"),
                                 detail: L("De map van dit model met alle bestanden (\(gb(store.status(m.id).have))) wordt van de schijf verwijderd: \(Paths.modelDir(m.id).path). Je kunt het model later opnieuw downloaden."),
                                 ask: true)
        case "choose_model":
            guard let m = model(a) else { return AppActionPlan(error: noModel(a)) }
            let role = arg(a, "role").lowercased()
            let image = store.catalog.images.contains(m)
            if ["images", "image", "afbeeldingen", "beeld"].contains(role) {
                return image ? AppActionPlan(title: L("\(m.name) kiezen voor afbeeldingen")) : AppActionPlan(error: "\(m.name) does not make images.")
            }
            if image { return AppActionPlan(error: "\(m.name) makes images: choose it with role images.") }
            if ["fast", "snel"].contains(role) {
                return m.id == app.selectedModelID ? AppActionPlan(error: "The heavy model cannot be the fast one too.") : AppActionPlan(title: L("\(m.name) kiezen als snel model"))
            }
            guard ["heavy", "zwaar", ""].contains(role) else { return AppActionPlan(error: "role is heavy, fast or images.") }
            if !store.status(m.id).isComplete { return AppActionPlan(error: "\(m.name) is not downloaded yet (download_model first).") }
            let restart = engineRuns && app.engine.model?.id != m.id
            return AppActionPlan(title: L("\(m.name) kiezen als zwaar model"), detail: restart ? L("De engine stopt en start daarna met dit model.") : nil, afterAnswer: restart)
        case "start_engine":
            if engineRuns { return AppActionPlan(error: "The engine runs already.") }
            return app.canStart ? AppActionPlan(title: L("Engine starten met \(app.selectedModel?.name ?? "")"))
                : AppActionPlan(error: "The engine cannot start now: the chosen model is not downloaded, or an image is being made.")
        case "stop_engine":
            return engineRuns ? AppActionPlan(title: L("Engine stoppen"), detail: L("Daarna antwoordt dit gesprek niet meer tot de engine weer draait."), afterAnswer: true)
                : AppActionPlan(error: "The engine is not running.")
        case "set_setting":
            let name = arg(a, "setting"), value = arg(a, "value")
            guard let (key, setting) = Self.setting(name) else {
                return AppActionPlan(error: "\"\(name)\" cannot be changed from the chat. Changeable: \(Self.settings.map(\.name).joined(separator: ", ")). Rights, keys, the server and the model folder only the user changes, in Settings.")
            }
            if let options = setting.options, !options.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                return AppActionPlan(error: "\(key) is one of: \(options.map { $0.isEmpty ? "\"\" (automatic)" : $0 }.joined(separator: ", ")).")
            }
            if setting.kind == "true/false" && Self.bool(value) == nil { return AppActionPlan(error: "\(key) is true or false.") }
            return AppActionPlan(title: L("Instelling \(key): \(setting.get()) → \(value)"))
        case "add_helper":
            return arg(a, "address").isEmpty ? AppActionPlan(error: "Give the address (host or host:port).") : AppActionPlan(title: L("Helper toevoegen: \(arg(a, "address"))"))
        case "use_helper":
            guard let h = helper(a) else { return AppActionPlan(error: "No helper \"\(arg(a, "helper"))\". Known: \(app.cluster.helpers.map(\.id).joined(separator: ", ")).") }
            let on = Self.bool(arg(a, "value")) ?? true
            return AppActionPlan(title: on ? L("Helper gebruiken: \(h.name)") : L("Helper niet meer gebruiken: \(h.name)"), detail: L("Dit geldt bij de volgende start van de engine."))
        case "cluster_role":
            let role = arg(a, "value").lowercased()
            guard role == "main" || role == "helper" else { return AppActionPlan(error: "value is main or helper.") }
            if role == "helper" {
                let cable = ClusterController.addresses().contains { $0.ip.hasPrefix("169.254.") }
                let detail = L("Deze Mac leent dan zijn geheugen en GPU uit aan een hoofd-Mac: de engine stopt, de helper start, en dit gesprek antwoordt niet meer tot de Mac weer hoofd-Mac is.")
                    + (cable || Settings.shared.clusterAllowLAN ? "" : " " + L("Er is geen Thunderbolt-kabel: sta ook het lokale netwerk toe, anders kan geen hoofd-Mac de helper bereiken."))
                return AppActionPlan(title: L("Deze Mac wordt helper in het cluster"), detail: detail, afterAnswer: engineRuns)
            }
            return AppActionPlan(title: L("Deze Mac wordt weer hoofd-Mac"))
        case "allow_lan":
            let on = Self.bool(arg(a, "value")) ?? true
            return on ? AppActionPlan(title: L("Lokaal netwerk toestaan voor het cluster"),
                                      detail: L("Let op: de helper heeft geen wachtwoord. Gebruik dit alleen op een netwerk dat je vertrouwt, nooit op een openbaar netwerk."), ask: true)
                : AppActionPlan(title: L("Alleen een Thunderbolt-kabel voor het cluster"))
        case "start_helper":
            if app.cluster.helperRunning { return AppActionPlan(error: "The helper runs already.") }
            return app.cluster.role != .helper ? AppActionPlan(error: "This Mac is the main Mac: cluster_role helper first.")
                : AppActionPlan(title: L("Helper starten"), afterAnswer: engineRuns)
        case "stop_helper":
            return app.cluster.helperRunning ? AppActionPlan(title: L("Helper stoppen")) : AppActionPlan(error: "The helper is not running.")
        case "make_image":
            if arg(a, "prompt").isEmpty { return AppActionPlan(error: "Give a prompt.") }
            guard let im = app.imageModel, store.status(im.id).isComplete else {
                return AppActionPlan(error: "No image model is downloaded (download_model \(app.models.catalog.images.first?.id ?? "") first).")
            }
            return AppActionPlan(title: L("Afbeelding maken: \(String(arg(a, "prompt").prefix(120)))"),
                                 detail: engineRuns ? L("De chatengine stopt zo nodig eerst, zodat er ruimte is voor het afbeeldingsmodel.") : nil, afterAnswer: engineRuns)
        default:
            return AppActionPlan(error: "Unknown action. Actions: \(AppTools.actions.joined(separator: ", ")).")
        }
    }

    func run(_ action: String, _ a: [String: Any], conversation: UUID) async -> String {
        let p = plan(action, a)
        if let error = p.error { return "Error: " + error }
        if p.afterAnswer {
            afterAnswer[conversation, default: []].append { [weak self] in _ = await self?.perform(action, a) }
            return "Approved. This happens as soon as your answer is done (\(action)). Finish your answer now and tell the user what will happen; do not call more tools for it."
        }
        return await perform(action, a)
    }

    func answerDone(_ conversation: UUID) {
        guard let todo = afterAnswer.removeValue(forKey: conversation) else { return }
        Task { for t in todo { await t() } }
    }

    private func show(_ pane: Pane) {
        AppNavigator.shared.pane = pane
    }

    private func perform(_ action: String, _ a: [String: Any]) async -> String {
        let store = app.models
        switch action {
        case "open_page":
            let page = arg(a, "page").lowercased()
            if page == "chat", let id = app.store.selection { show(.chat(id)) } else if let pane = Self.pages[page] { show(pane) }
            return "The \(page) screen is open."
        case "open_help":
            let id = HelpCenter.search(arg(a, "topic"), in: HelpCenter.topics()).first?.id ?? "start"
            HelpCenter.shared.open(id)
            return "The help is open at \(id)."
        case "new_conversation":
            app.store.newConversation()
            if let id = app.store.selection { show(.chat(id)) }
            return "A new conversation is open."
        case "download_model":
            let m = model(a)!
            store.startDownload(m.id)
            return "The download of \(m.name) started; it shows on its card under Models and goes on in the background (app_status shows how far)."
        case "pause_download":
            store.stopDownload(model(a)!.id)
            return "The download is paused; download_model resumes it."
        case "check_update":
            let m = model(a)!
            store.checkForUpdate(m.id)
            for _ in 0..<60 where store.checking.contains(m.id) { try? await Task.sleep(for: .milliseconds(500)) }
            return store.checkResult[m.id]?.text ?? "Checked."
        case "delete_model":
            let m = model(a)!
            return store.deleteModel(m.id) ?? "\(m.name) is deleted from the disk."
        case "choose_model":
            let m = model(a)!
            let role = arg(a, "role").lowercased()
            if store.catalog.images.contains(m) { Settings.shared.imageModel = m.id; return "\(m.name) makes the images now." }
            if ["fast", "snel"].contains(role) { Settings.shared.fastModel = m.id; return "\(m.name) is the fast model now." }
            await app.select(m.id)
            return "\(m.name) is the heavy model now\(engineRuns ? " and the engine is starting with it" : "; start_engine starts it")."
        case "start_engine":
            app.startEngine()
            return "The engine is starting; that can take a minute for a large model."
        case "stop_engine":
            app.engine.stop()
            return "The engine is stopping."
        case "set_setting":
            let (key, setting) = Self.setting(arg(a, "setting"))!
            guard setting.set(arg(a, "value")) else { return "Error: that is not a value for \(key)." }
            if key == "featureTelegram" { TelegramService.shared.restart() }
            let later = ["contextSize", "mtp", "ngramMod", "vision"].contains(key) ? " It counts after the engine restarts." : ""
            return "\(key) is now \(setting.get()).\(later)"
        case "find_helpers":
            app.cluster.recheckManual()
            try? await Task.sleep(for: .seconds(3))
            let list = app.cluster.helpers
            return list.isEmpty
                ? "No helpers found. Each other Mac needs MacAIMagic (or a PC WinAIMagic) as helper with its helper started, on a Thunderbolt cable or with the local network allowed on both. A helper on another subnet: add_helper with its address."
                : "Helpers: " + list.map { "\($0.id) \($0.name) (\($0.chip), \(String(format: "%.1f", $0.gpuGB)) GB\($0.unreachable ? ", not reachable" : ""))" }.joined(separator: "; ")
        case "add_helper":
            let address = arg(a, "address")
            app.cluster.addManual(address)
            try? await Task.sleep(for: .seconds(5))
            let host = address.split(separator: ":").first.map(String.init) ?? address
            guard let added = app.cluster.helpers.first(where: { $0.manual && $0.host == host }) else { return "Added. It is in the list." }
            return added.unreachable ? "Added. \(added.id) does not answer: is its helper started, and does its firewall allow the app?"
                : "Added. \(added.id) answers, \(String(format: "%.1f", added.gpuGB)) GB for the model."
        case "use_helper":
            let h = helper(a)!
            if Self.bool(arg(a, "value")) == false { app.cluster.selected.remove(h.id) } else { app.cluster.selected.insert(h.id) }
            return "\(h.name) is \(app.cluster.selected.contains(h.id) ? "in use" : "not in use") from the next engine start."
        case "cluster_role":
            if arg(a, "value").lowercased() == "helper" {
                if engineRuns { await app.engine.stopAndWait() }
                Settings.shared.clusterRole = "helper"
                app.cluster.startHelper()
                return app.cluster.helperRunning ? "This Mac is a helper now, on \(app.cluster.helperAddress)."
                    : "This Mac is a helper, but the helper did not start: " + app.cluster.helperLog.suffix(2).joined(separator: " ")
            }
            app.cluster.stopHelper()
            Settings.shared.clusterRole = "main"
            return "This Mac is the main Mac again."
        case "allow_lan":
            Settings.shared.clusterAllowLAN = Self.bool(arg(a, "value")) ?? true
            if app.cluster.helperRunning { app.cluster.restartHelper() }
            return Settings.shared.clusterAllowLAN ? "The local network is allowed for the cluster." : "Only a Thunderbolt cable now."
        case "start_helper":
            if engineRuns { await app.engine.stopAndWait() }
            app.cluster.startHelper()
            return app.cluster.helperRunning ? "The helper runs on \(app.cluster.helperAddress)."
                : "The helper did not start: " + app.cluster.helperLog.suffix(2).joined(separator: " ")
        case "stop_helper":
            app.cluster.stopHelper()
            return "The helper is stopped."
        case "make_image":
            let size = ImageSize(key: Settings.shared.imageSize).flatMap { ImagePlanner.sizes.contains($0) ? $0 : nil } ?? ImagePlanner.defaultSize(app.system)
            show(.images)
            app.makeImage(prompt: arg(a, "prompt"), size: size)
            return "The image is being made on the Beeld screen (\(size.width) x \(size.height))."
        default:
            return "Unknown action."
        }
    }
}
