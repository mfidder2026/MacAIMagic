import Foundation

/// What the app does for the model: its state in plain lines, and the actions of app_action. The app implements it
/// (AppControl); tests give their own.
@MainActor
protocol AppControlling: AnyObject {
    func status() -> String
    /// The settings set_setting may change, with their values where those are fixed ("thinking (true/false)").
    var settingNames: [String] { get }
    /// What the action will do, for the approval card, or why it cannot.
    func plan(_ action: String, _ args: [String: Any]) -> AppActionPlan
    func run(_ action: String, _ args: [String: Any], conversation: UUID) async -> String
    /// This conversation's answer is done: what waited for it runs now.
    func answerDone(_ conversation: UUID)
}

/// `afterAnswer`: it would stop the engine this conversation runs on, so it waits until the answer is done.
/// `ask`: it always asks (deleting a model), whatever the rights. `readOnly`: no card.
struct AppActionPlan {
    var title: String? = nil
    var detail: String? = nil
    var error: String? = nil
    var afterAnswer = false
    var ask = false
    var readOnly = false
}

/// The app knows itself: the model reads MacAIMagic's own help (app_help), sees how the app and this Mac stand now
/// (app_status), does what the user asks of the app (app_action: models, engine, settings, screens), and makes or
/// changes the user's own skills (create_skill), instead of guessing how the app works or only explaining it.
/// Taken over from WinAIMagic 9ab7bef, with the Mac's own screens, settings and cluster.
enum AppTools {
    static let names: Set<String> = ["app_help", "app_status", "app_action", "create_skill"]

    static let actions = [
        "open_page", "open_help", "download_model", "pause_download", "check_update", "delete_model",
        "choose_model", "start_engine", "stop_engine", "set_setting", "make_image", "new_conversation",
        "find_helpers", "add_helper", "use_helper", "cluster_role", "allow_lan", "start_helper", "stop_helper",
    ]

    private static func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description,
                      "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any]] as [String: Any]]
    }

    static func definitions(skills: Bool, settings: [String]) -> [[String: Any]] {
        let settingList = settings.isEmpty ? "see app_status" : settings.joined(separator: ", ")
        var tools: [[String: Any]] = [
            function("app_help", "Read MacAIMagic's own help: what the app can do and how. Without arguments it lists the topics; give a topic id, or a few words to search for. Use it whenever the user asks about MacAIMagic itself (its screens, models, settings, skills, tasks, system management, the API, problems), instead of guessing.",
                     ["topic": prop("string", "A topic id from the list, e.g. skills or models"),
                      "query": prop("string", "Words to search the help for")]),
            function("app_status", "How MacAIMagic and this Mac stand right now: the app's version, the Mac's chip, memory and free disk, every model in the catalog with its id (downloaded or not, whether it fits in memory or streams from the SSD, which is recommended, downloads running), which models run (heavy, fast, images), the cluster, the settings with their names and values. Read-only. Read it before app_action.", [:]),
            function("app_action", "Do something in MacAIMagic itself for the user, instead of explaining how: "
                     + "open_page (page: chat, live, models, documents, images, tasks, cluster, compare, system, help), open_help (topic), "
                     + "download_model, pause_download, check_update, delete_model (model: an id from app_status), "
                     + "choose_model (role: heavy, fast or images; model: id), start_engine, stop_engine, "
                     + "set_setting (setting and value; settings: \(settingList)), make_image (prompt, in English), new_conversation. "
                     + "Cluster (several Macs share one model's memory): find_helpers (asks the helpers again and lists them), add_helper (address, host or host:port), use_helper (helper: its id host:port; value: true or false), cluster_role (value: main or helper), allow_lan (value: true or false; needed without a Thunderbolt cable), start_helper, stop_helper. To build a cluster: on each other Mac that Mac's own MacAIMagic becomes helper (cluster_role helper; it starts the helper); on the main Mac find_helpers, use_helper for each, then start_engine. "
                     + "Only do what the user asked for: never download, delete or switch a model on your own, also not one you recommend. The user approves a change on a card first. An action that stops the engine this conversation runs on (stop_engine, a new heavy model, make_image, becoming a helper) happens when your answer is done: finish your answer then, and say what will happen.",
                     ["action": ["type": "string", "enum": actions] as [String: Any],
                      "model": prop("string", "A model id from app_status"),
                      "role": prop("string", "heavy, fast or images"),
                      "page": prop("string", "The screen to open"),
                      "topic": prop("string", "A help topic id"),
                      "setting": prop("string", "A setting name from app_status"),
                      "value": prop("string", "The new value of the setting, or true/false, main/helper"),
                      "prompt": prop("string", "What the image should show, in English"),
                      "address": prop("string", "A helper's address, host or host:port"),
                      "helper": prop("string", "A helper's id (host:port) from app_status")],
                     required: ["action"]),
        ]
        if skills {
            tools.append(function("create_skill", "Make a new skill of the user's own, or replace one of their own skills, so it shows in the skill list and can be loaded with use_skill. A skill is instructions for one subject with commands that work on this Mac. The user approves it first. Do not put a skill in a work folder or in MACAIMAGIC.md: this tool is the only place skills go.",
                                  ["name": prop("string", "Short name, lower case with hyphens, e.g. c64-assembler"),
                                   "description": prop("string", "One line: what the skill is about and when to load it"),
                                   "instructions": prop("string", "The skill itself in Markdown: paths, commands, steps, common mistakes")],
                                  required: ["name", "description", "instructions"]))
        }
        return tools
    }

    /// For the system prompt: what this app is, so the model knows where it runs and asks the help instead of guessing.
    static func promptSection(skills: Bool) -> String {
        L("Je draait in MacAIMagic, een app die grote AI-modellen helemaal op deze Mac draait. De app heeft schermen voor chatten, modellen, documenten, afbeeldingen (Beeld), taken, een cluster, vergelijken, het systeem en de hulp. Je kent de app: lees met app_help hoe iets werkt en met app_status hoe de app en deze Mac er nu voor staan, en gok niet. Vraagt de gebruiker iets te doen in de app (een model downloaden, kiezen of starten, een instelling wijzigen, een scherm openen, een afbeelding maken), doe het dan zelf met app_action in plaats van uit te leggen hoe het moet. Doe alleen wat de gebruiker vraagt: download, verwijder of wissel een model nooit uit jezelf, ook niet als je het aanraadt.")
            + (skills ? " " + L("Vraagt de gebruiker om een skill te maken of aan te passen, gebruik dan create_skill; een skill hoort niet in de werkmap of in MACAIMAGIC.md.") : "")
    }

    // MARK: - running

    static func help(_ call: ToolCall) -> String {
        let a = WorkspaceTools.args(call)
        let topics = HelpCenter.topics()
        let id = (a["topic"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let query = (a["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !topics.isEmpty else { return "The help texts are missing in this version of the app." }
        var found = id.isEmpty ? nil : topics.first { $0.id.caseInsensitiveCompare(id) == .orderedSame || $0.title.caseInsensitiveCompare(id) == .orderedSame }
        if found == nil, !(query.isEmpty && id.isEmpty) { found = HelpCenter.search(query.isEmpty ? id : query, in: topics).first }
        if let found { return "# \(found.title) (topic \(found.id))\n\n\(found.body)" }
        let list = topics.map { "- \($0.id): \($0.title)" }.joined(separator: "\n")
        return (id.isEmpty && query.isEmpty ? "" : "Nothing found for that. ") + "The help topics of MacAIMagic (read one with app_help topic):\n" + list
    }

    /// A skill name as a folder: lower case letters, digits and hyphens.
    static func skillName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (1...60).contains(name.count) ? name : nil
    }

    /// The skill the model asked for, as a SKILL.md; nil when the name or the instructions are missing.
    static func skill(_ call: ToolCall) -> (name: String, description: String, text: String)? {
        let a = WorkspaceTools.args(call)
        guard let name = skillName(a["name"] as? String ?? "") else { return nil }
        let description = (a["description"] as? String ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let body = (a["instructions"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (name, description, "---\nname: \(name)\ndescription: \(description)\nplatform: macos\n---\n\(body)\n")
    }

    /// Whether this replaces a skill: one of the user's own (the file is overwritten) or a built-in one (the user's
    /// copy wins).
    static func replaces(_ name: String, userFolder: URL = Paths.userSkills) -> String? {
        if FileManager.default.fileExists(atPath: userFolder.appendingPathComponent(name).appendingPathComponent("SKILL.md").path) { return "own" }
        let builtIn = Paths.bundledSkills.map { Skills.load(from: [$0]) } ?? []
        return builtIn.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } ? "builtin" : nil
    }

    static func writeSkill(_ name: String, _ text: String, userFolder: URL = Paths.userSkills) throws -> URL {
        let dir = userFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func label(for call: ToolCall) -> String {
        let a = WorkspaceTools.args(call)
        switch call.name {
        case "app_help":
            let what = (a["topic"] as? String) ?? (a["query"] as? String) ?? ""
            return what.isEmpty ? L("Hulp lezen") : L("Hulp lezen: \(what)")
        case "app_status": return L("Stand van de app bekijken")
        case "app_action": return L("In de app: \(a["action"] as? String ?? "")")
        case "create_skill": return L("Skill maken: \(a["name"] as? String ?? "")")
        default: return call.name
        }
    }
}
