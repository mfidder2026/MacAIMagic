import Foundation

/// System management (Instellingen → Experimenteel): the model reads this Mac's settings with `system_read`, and changes
/// them with `system_change`, a plan of steps that each have a check, an apply and an undo. The app shows the plan,
/// runs it after the user's yes, records the values before and after, and can undo it later (`system_undo`, or the
/// button under Systeem). Admin steps go through macOS's own password dialog: the model never sees the password.
/// Sensitive changes are not blocked; the approval card warns about them.
enum SystemTools {
    static let names: Set<String> = ["system_read", "system_change", "system_undo"]

    static let definitions: [[String: Any]] = [
        function("system_read", "Read this Mac's settings and state without changing anything (diagnosis). Runs one command in the home folder. Only read-only commands are allowed, without pipes, ;, &&, redirection or $(…): for example defaults read, pmset -g, networksetup -getdnsservers \"Wi-Fi\", scutil --dns, launchctl list, system_profiler, df -h, du -sh, top -l 1, log show, brew list, softwareupdate --list, tmutil listlocalsnapshots /, ls, cat. For a change, use system_change.",
                 ["command": ["type": "string", "description": "One read-only command line"]], required: ["command"]),
        function("system_change", "Change this Mac's settings with a plan the user approves first. Give every step a check (a read-only command that shows the current value), an apply (the change, zsh) and an undo (puts the old value back; write the value from the check in it). Set admin to true for a step that needs administrator rights: macOS then asks the user for the password; never use sudo. Admin steps run as root, so write full paths instead of ~. Restart what reads the setting in the same apply (killall Dock). Use the skill for the subject first when there is one.",
                 ["summary": ["type": "string", "description": "What the plan does, in one sentence for the user"],
                  "steps": ["type": "array", "items": ["type": "object", "properties": [
                      "title": ["type": "string", "description": "The step in plain words, e.g. Dock on the left"],
                      "check": ["type": "string", "description": "Read-only command that shows the current value"],
                      "apply": ["type": "string", "description": "The command that makes the change"],
                      "undo": ["type": "string", "description": "The command that puts the old value back"],
                      "admin": ["type": "boolean", "description": "true when the step needs administrator rights"],
                  ] as [String: Any], "required": ["title", "apply", "undo"]] as [String: Any]]],
                 required: ["summary", "steps"]),
        function("system_undo", "Undo an earlier system change by its id (the id system_change returned). The user approves it first.",
                 ["id": ["type": "string", "description": "The id of the change"]], required: ["id"]),
    ]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    static func promptSection() -> String {
        L("Je kunt de instellingen van deze Mac bekijken met system_read (alleen lezen, voor diagnose) en wijzigen met system_change: een plan met per stap een check, een wijziging en een ongedaanmaking. De gebruiker keurt het plan eerst goed; stappen die beheerdersrechten nodig hebben markeer je met admin, dan vraagt macOS zelf om het wachtwoord. Lees eerst de huidige waarde, gok nooit een instelling, en leg bij een gevoelige wijziging (firewall, Gatekeeper, FileVault, gebruikers) uit wat het betekent. Gaat iets niet met een commando, open dan het juiste paneel van Systeeminstellingen met open \"x-apple.systempreferences:…\" en zeg wat de gebruiker moet aanklikken.")
    }

    // MARK: - reading only

    /// The words of a command line, or nil when it does more than run one program: $, `, a line break, or ; | & < > ( )
    /// outside quotes. Quotes are taken off.
    static func words(_ command: String) -> [String]? {
        if command.contains(where: { "$`\n\r".contains($0) }) { return nil }
        var out: [String] = []
        var word = ""
        var quote: Character?
        var inWord = false
        for c in command {
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; inWord = true; continue }
            if ";|&<>()".contains(c) { return nil }
            if c == " " || c == "\t" {
                if inWord { out.append(word); word = ""; inWord = false }
                continue
            }
            word.append(c); inWord = true
        }
        guard quote == nil else { return nil }
        if inWord { out.append(word) }
        return out.isEmpty ? nil : out
    }

    /// Whether the app may run this without asking: one program from a list of read-only commands, with arguments that
    /// cannot change anything. Everything else is a change.
    static func isReadOnly(_ command: String) -> Bool {
        guard let w = words(command) else { return false }
        let program = (w[0] as NSString).lastPathComponent
        let args = Array(w.dropFirst())
        let first = args.first ?? ""
        switch program {
        case "sw_vers", "system_profiler", "df", "du", "uptime", "vm_stat", "whoami", "id", "hostname", "uname", "ps",
             "last", "ls", "cat", "head", "tail", "wc", "mdfind", "mdls", "file", "stat", "which", "date", "ioreg",
             "lsof", "networkQuality", "kextstat":
            return true
        case "sfltool": return first == "dumpbtm"
        case "dscacheutil": return first == "-q"
        case "find": return !args.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls"].contains($0) }
        case "top": return args.contains("-l")
        case "sysctl": return !args.contains { $0.contains("=") || $0 == "-w" }
        case "pmset": return first.hasPrefix("-g")
        case "networksetup": return first.hasPrefix("-get") || first.hasPrefix("-list") || first == "-version"
        case "scutil": return ["--get", "--dns", "--proxy", "--nwi"].contains(first)
        case "defaults":
            let verb = args.first { !$0.hasPrefix("-") } ?? ""
            return ["read", "read-type", "domains", "find"].contains(verb)
        case "launchctl": return ["list", "print", "print-disabled", "version"].contains(first)
        case "log": return first == "show" || first == "stats"
        case "brew": return ["list", "ls", "info", "outdated", "search", "--version", "config", "deps", "leaves", "doctor", "--prefix"].contains(first)
        case "softwareupdate": return !args.isEmpty && args.allSatisfy { ["--list", "-l", "--no-scan", "--history"].contains($0) }
        case "tmutil": return ["listlocalsnapshots", "status", "destinationinfo", "listbackups", "latestbackup", "machinedirectory", "version", "listlocalsnapshotdates"].contains(first)
        case "fdesetup", "csrutil": return first == "status"
        case "spctl": return ["--status", "--assess", "-a"].contains(first)
        case "socketfilterfw": return !args.isEmpty && args.allSatisfy { $0.hasPrefix("--get") || $0 == "--listapps" }
        case "diskutil": return first == "list" || first == "info" || (first == "apfs" && args.dropFirst().first == "list")
        case "ifconfig": return args.isEmpty || args == ["-a"] || args == ["-l"] || (args.count == 1 && !args[0].hasPrefix("-"))
        case "ping": return args.contains("-c")
        case "profiles": return ["list", "show", "status"].contains(first)
        case "sysadminctl": return args == ["-screenLock", "status"]
        case "nvram": return args == ["-p"] || args == ["-xp"] || args == ["-x", "-p"]
        case "systemextensionsctl", "shortcuts": return first == "list"
        case "pkgutil": return ["--pkgs", "--pkg-info", "--files", "--file-info"].contains(first)
        case "dscl":
            let writes = ["-create", "-delete", "-append", "-merge", "-passwd", "-change", "-changei", "-mcxset", "-mcxdelete"]
            return args.contains { ["-read", "-list", "-readall", "-search"].contains($0) } && !args.contains { writes.contains($0) }
        default: return false
        }
    }

    // MARK: - plans

    struct Step: Codable, Hashable {
        var title: String
        var check: String
        var apply: String
        var undo: String
        var admin: Bool
    }

    struct StepResult: Codable, Hashable {
        var before: String
        var after: String
        var output: String
        var ok: Bool
        var ran: Bool
    }

    /// One plan the model carried out, kept in Changes/<id>/plan.json.
    struct Change: Codable, Identifiable, Hashable {
        var id: String
        var date: Date
        var summary: String
        var steps: [Step]
        var results: [StepResult]
        /// Preference domains exported before the change, domain → file in the change's folder.
        var exports: [String: String] = [:]
        var snapshot = false
        var undone: Date? = nil
        var undoReport: String? = nil

        var admin: Bool { steps.contains(where: \.admin) }
        var succeeded: Bool { results.allSatisfy { $0.ok || !$0.ran } && results.contains(where: \.ran) }
    }

    enum PlanError: LocalizedError {
        case noSteps, emptyApply(Int)
        var errorDescription: String? {
            switch self {
            case .noSteps: return "The plan has no steps. Give steps with title, check, apply and undo."
            case .emptyApply(let n): return "Step \(n) has no apply command."
            }
        }
    }

    static func plan(from call: ToolCall) throws -> (summary: String, steps: [Step]) {
        let a = WorkspaceTools.args(call)
        var raw = a["steps"] as? [[String: Any]]
        // some models send the array as a JSON string
        if raw == nil, let s = a["steps"] as? String, let d = s.data(using: .utf8) {
            raw = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]
        }
        guard let raw, !raw.isEmpty else { throw PlanError.noSteps }
        var steps: [Step] = []
        for (i, s) in raw.enumerated() {
            let apply = (s["apply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apply.isEmpty else { throw PlanError.emptyApply(i + 1) }
            let admin = (s["admin"] as? Bool) ?? ((s["admin"] as? String)?.lowercased() == "true")
            steps.append(Step(title: (s["title"] as? String ?? "").isEmpty ? apply : s["title"] as! String,
                              check: (s["check"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              apply: apply,
                              undo: (s["undo"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              admin: admin))
        }
        return ((a["summary"] as? String ?? "").isEmpty ? steps[0].title : a["summary"] as! String, steps)
    }

    // MARK: - warnings

    /// Changes that weaken the Mac's protection or are hard to undo. They are not blocked: the card says what they mean.
    static let sensitive: [(pattern: String, warning: Loc)] = [
        (#"socketfilterfw\s+--setglobalstate\s+off"#, "De firewall gaat uit: programma's op deze Mac zijn dan van buitenaf bereikbaar."),
        (#"spctl\s+--(master-disable|global-disable|disable)"#, "Gatekeeper gaat uit: macOS controleert dan niet meer of apps van een bekende ontwikkelaar komen."),
        (#"\bcsrutil\b"#, "Systeemintegriteitsbescherming (SIP) beschermt macOS zelf; die kan alleen vanuit Herstel worden gewijzigd."),
        (#"fdesetup\s+(disable|remove)"#, "FileVault gaat uit: de schijf is dan niet meer versleuteld als de Mac kwijtraakt."),
        (#"\bdscl\b|\bdseditgroup\b|sysadminctl\s+-(addUser|deleteUser|resetPasswordFor|secureTokenOff)"#, "Dit wijzigt gebruikersaccounts of groepen."),
        (#"TCC\.db|\btccutil\b"#, "Dit wijzigt privacyrechten (camera, microfoon, schermopname, toegang tot bestanden)."),
        (#"\bprofiles\s+(install|remove|-I|-R)"#, "Een configuratieprofiel kan veel instellingen tegelijk vastzetten."),
        (#"\brm\s+-[a-zA-Z]*[rR]"#, "rm -r verwijdert bestanden definitief, niet via de prullenmand; dit is niet ongedaan te maken."),
        (#"pmset.*\b(hibernatemode|standby|autopoweroff)\b"#, "Bij deze slaapstand-instelling kan werk verloren gaan als de batterij leeg raakt."),
        (#"\bnvram\b"#, "NVRAM-instellingen gelden bij het opstarten; een verkeerde waarde kan het opstarten verstoren."),
        (#"\bsudo\b"#, "sudo werkt hier niet: zonder wachtwoordvenster blijft het commando hangen. Het model had de stap als beheerder moeten markeren."),
        (#"\b(curl|wget)\b[^\n]*\|\s*(ba|z)?sh\b"#, "Dit voert een script van internet uit zonder dat iemand het heeft gelezen."),
        (#"launchctl\s+(bootout|disable|unload|remove)[^\n]*com\.apple\."#, "Dit stopt een dienst van macOS zelf."),
        (#"networksetup\s+-set(web|secureweb|socks)proxy"#, "Een proxy laat al het webverkeer via een ander adres lopen."),
        (#"/etc/hosts"#, "Het hosts-bestand bepaalt waar websites naartoe gaan."),
        (#"softwareupdate[^\n]*(-i\b|--install)"#, "Een macOS-update installeren kan de Mac laten herstarten."),
        (#"\b(shutdown|reboot|halt)\b"#, "De Mac wordt herstart of uitgezet; niet bewaard werk gaat verloren."),
    ]

    static func warnings(for steps: [Step], afterWeb: Bool) -> [String] {
        var out: [String] = []
        let text = steps.map { $0.apply + "\n" + $0.undo }.joined(separator: "\n")
        for s in sensitive where text.range(of: s.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            out.append(L(s.warning))
        }
        if steps.contains(where: { $0.undo.isEmpty }) {
            out.append(L("Niet elke stap heeft een manier om hem ongedaan te maken."))
        }
        if afterWeb {
            out.append(L("Dit plan volgt op het lezen van het web. Een webpagina kan het model instructies geven: controleer of dit is wat jij wilde."))
        }
        return out
    }

    // MARK: - running

    static func exitCode(_ output: String) -> Int32? {
        guard let r = output.range(of: #"\[exit code (-?\d+)\]\s*$"#, options: .regularExpression) else { return nil }
        return Int32(output[r].filter { $0.isNumber || $0 == "-" })
    }

    /// The output without the app's status line.
    static func clean(_ output: String) -> String {
        var t = output
        if let r = t.range(of: #"\n?\[(exit code -?\d+|stopped[^\]]*)\]\s*$"#, options: .regularExpression) { t.removeSubrange(r) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "(no output)" { t = "" }
        return t.count > 2000 ? String(t.prefix(2000)) + " …" : t
    }

    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func runUser(_ command: String, timeout: Int = 120) async -> (output: String, ok: Bool) {
        let out = await WorkspaceTools.runShell(command, in: home, timeout: timeout)
        return (clean(out), exitCode(out) == 0)
    }

    /// A text inside an AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The commands as root, after one password dialog of macOS. Each gets its own output and exit code.
    static func runAdmin(_ commands: [String], prompt: String, timeout: Int = 900) async -> [(output: String, ok: Bool)] {
        var script = ""
        for (i, c) in commands.enumerated() {
            script += "echo '@@STEP \(i)'\n( \(c) ) 2>&1\necho \"@@EXIT $?\"\n"
        }
        let apple = "do shell script \(appleScriptString(script)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let raw = await WorkspaceTools.runShell("", in: home, timeout: timeout, executable: "/usr/bin/osascript", arguments: ["-e", apple])
        let text = raw.replacingOccurrences(of: "\r", with: "\n")
        var results = Array(repeating: (output: "", ok: false), count: commands.count)
        guard text.contains("@@STEP 0") else {
            // the dialog was cancelled, or osascript could not run it
            let reason = text.contains("-128") ? "Cancelled by the user in the password dialog." : clean(text)
            return results.map { _ in (reason, false) }
        }
        for part in text.components(separatedBy: "@@STEP ").dropFirst() {
            let lines = part.components(separatedBy: "\n")
            guard let i = Int(lines[0].trimmingCharacters(in: .whitespaces)), i < commands.count else { continue }
            var body = Array(lines.dropFirst())
            var ok = false
            if let e = body.lastIndex(where: { $0.hasPrefix("@@EXIT ") }) {
                ok = body[e] == "@@EXIT 0"
                body = Array(body[..<e])
            }
            results[i] = (clean(body.joined(separator: "\n")), ok)
        }
        return results
    }

    /// Runs the commands in order: one at a time for the user, and runs of admin steps together, so one dialog
    /// covers them. Stops at the first that fails; the rest stay unrun (nil).
    static func runInOrder(_ items: [(command: String, admin: Bool)], prompt: String, snapshot: Bool) async -> [(output: String, ok: Bool)?] {
        var results: [(output: String, ok: Bool)?] = Array(repeating: nil, count: items.count)
        var i = 0
        var snapshotPending = snapshot
        while i < items.count {
            if items[i].admin {
                var j = i
                while j < items.count && items[j].admin { j += 1 }
                var commands = items[i..<j].map(\.command)
                if snapshotPending { commands.insert("/usr/bin/tmutil localsnapshot", at: 0) }
                var out = await runAdmin(commands, prompt: prompt)
                if snapshotPending { out.removeFirst(); snapshotPending = false }
                for k in i..<j {
                    results[k] = out[k - i]
                    if !out[k - i].ok { return results }
                }
                i = j
            } else {
                let out = await runUser(items[i].command)
                results[i] = out
                if !out.ok { return results }
                i += 1
            }
        }
        return results
    }

    /// The preference domains a step writes with `defaults write` (-g is NSGlobalDomain); -currentHost is skipped.
    static func domains(in command: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\bdefaults\s+write\s+("[^"]+"|'[^']+'|\S+)"#) else { return [] }
        let ns = command as NSString
        return re.matches(in: command, range: NSRange(location: 0, length: ns.length)).map {
            var d = ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if d == "-g" || d == "-globalDomain" { d = "NSGlobalDomain" }
            return d
        }.filter { $0 != "-currentHost" && !$0.hasPrefix("/") }
    }

    /// The current value for each step's check, when the check only reads (for the approval card).
    static func preview(_ steps: [Step]) async -> [String?] {
        var out: [String?] = []
        for s in steps {
            if !s.check.isEmpty, isReadOnly(s.check) {
                let r = await runUser(s.check, timeout: 20)
                out.append(r.output.isEmpty ? L("(leeg)") : r.output)
            } else {
                out.append(nil)
            }
        }
        return out
    }

    static func newID(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    /// Carries out an approved plan: exports, values before, the changes, values after, and the record.
    static func apply(summary: String, steps: [Step], snapshot: Bool, folder: URL = Paths.changes) async -> Change {
        var change = Change(id: newID(), date: Date(), summary: summary, steps: steps,
                            results: steps.map { _ in StepResult(before: "", after: "", output: "", ok: false, ran: false) },
                            snapshot: snapshot && steps.contains(where: \.admin))
        let dir = folder.appendingPathComponent(change.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // an exact copy of every preference domain the plan writes, so undo does not depend on the model's undo alone
        for domain in Set(steps.filter { !$0.admin }.flatMap { domains(in: $0.apply) }).sorted() {
            let file = domain.replacingOccurrences(of: "/", with: "_") + ".plist"
            let out = await WorkspaceTools.runShell("", in: home, timeout: 30, executable: "/usr/bin/defaults",
                                                    arguments: ["export", domain, dir.appendingPathComponent(file).path])
            if exitCode(out) == 0 { change.exports[domain] = file }
        }
        for (i, s) in steps.enumerated() where !s.check.isEmpty {
            change.results[i].before = await runUser(s.check, timeout: 30).output
        }
        let ran = await runInOrder(steps.map { ($0.apply, $0.admin) }, prompt: L("MacAIMagic wil deze wijziging maken: \(summary)"), snapshot: change.snapshot)
        for (i, r) in ran.enumerated() {
            guard let r else { change.results[i].output = "Not run: an earlier step failed."; continue }
            change.results[i].ran = true
            change.results[i].ok = r.ok
            change.results[i].output = r.output
            if !steps[i].check.isEmpty { change.results[i].after = await runUser(steps[i].check, timeout: 30).output }
        }
        save(change, folder: folder)
        return change
    }

    /// Puts an earlier change back: the undo commands of the steps that ran, last first; then each exported preference
    /// domain that still differs is imported again. Then every check is compared with its value from before.
    static func undo(_ original: Change, folder: URL = Paths.changes) async -> Change {
        var change = original
        let dir = folder.appendingPathComponent(change.id, isDirectory: true)
        let order = change.steps.indices.reversed().filter { change.results[$0].ran && !change.steps[$0].undo.isEmpty }
        let ran = await runInOrder(order.map { (change.steps[$0].undo, change.steps[$0].admin) },
                                   prompt: L("MacAIMagic wil deze wijziging ongedaan maken: \(change.summary)"), snapshot: false)
        var lines: [String] = []
        for (k, i) in order.enumerated() {
            let r = ran[k]
            lines.append("\(i + 1). \(change.steps[i].title): " + (r == nil ? "not run" : r!.ok ? "undone" : "failed: \(r!.output)"))
        }
        var restored = false
        for (domain, file) in change.exports.sorted(by: { $0.key < $1.key }) {
            let saved = dir.appendingPathComponent(file)
            let now = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plist")
            _ = await WorkspaceTools.runShell("", in: home, timeout: 30, executable: "/usr/bin/defaults", arguments: ["export", domain, now.path])
            let same = (try? Data(contentsOf: now)).map { NSDictionary(contentsOf: now) == NSDictionary(contentsOf: saved) && !$0.isEmpty } ?? false
            try? FileManager.default.removeItem(at: now)
            if !same {
                let out = await WorkspaceTools.runShell("", in: home, timeout: 30, executable: "/usr/bin/defaults", arguments: ["import", domain, saved.path])
                if exitCode(out) == 0 { restored = true; lines.append("\(domain): restored from the copy made before the change") }
            }
        }
        if restored {
            // what reads those settings sees them only after a restart
            let programs = Set(change.steps.flatMap { killalls(in: $0.apply + "\n" + $0.undo) })
            for p in programs.sorted() { _ = await runUser("killall \(p)", timeout: 20) }
        }
        for (i, s) in change.steps.enumerated() where change.results[i].ran && !s.check.isEmpty {
            let now = await runUser(s.check, timeout: 30).output
            let before = change.results[i].before
            lines.append("\(i + 1). check: " + (now == before ? "back to \"\(before.prefix(200))\"" : "now \"\(now.prefix(200))\", before it was \"\(before.prefix(200))\""))
        }
        change.undone = Date()
        change.undoReport = lines.joined(separator: "\n")
        save(change, folder: folder)
        return change
    }

    static func killalls(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\bkillall\s+([A-Za-z][A-Za-z0-9_.-]*)"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    // MARK: - the record

    static func save(_ change: Change, folder: URL = Paths.changes) {
        let dir = folder.appendingPathComponent(change.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(change).write(to: dir.appendingPathComponent("plan.json"), options: .atomic)
    }

    /// Every recorded change, newest first.
    static func load(folder: URL = Paths.changes) -> [Change] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { try? dec.decode(Change.self, from: Data(contentsOf: $0.appendingPathComponent("plan.json"))) }
            .sorted { $0.date > $1.date }
    }

    /// What the model reads back after a plan ran.
    static func report(_ c: Change) -> String {
        var lines = ["Change \(c.id): \(c.summary)"]
        for (i, s) in c.steps.enumerated() {
            let r = c.results[i]
            let state = !r.ran ? "not run" : r.ok ? "ok" : "FAILED"
            var line = "\(i + 1). \(s.title): \(state)"
            if !s.check.isEmpty { line += " — before: \"\(r.before.prefix(300))\", after: \"\(r.after.prefix(300))\"" }
            if !r.ok && !r.output.isEmpty { line += "\n   output: \(r.output.prefix(800))" }
            lines.append(line)
        }
        lines.append(c.succeeded
                     ? "Tell the user what changed. They can undo it under Systeem in the app, or you with system_undo id \(c.id)."
                     : "Not everything worked. Tell the user what did and did not change; offer system_undo id \(c.id) for the steps that ran.")
        return lines.joined(separator: "\n")
    }

    static func label(for call: ToolCall) -> String {
        let a = WorkspaceTools.args(call)
        switch call.name {
        case "system_read": return L("Systeem lezen: \(a["command"] as? String ?? "")")
        case "system_change": return L("Systeemwijziging: \(a["summary"] as? String ?? "")")
        case "system_undo": return L("Ongedaan maken: \(a["id"] as? String ?? "")")
        default: return call.name
        }
    }
}

/// The recorded system changes, for the list under Systeem.
@MainActor
final class ChangeLog: ObservableObject {
    static let shared = ChangeLog()
    @Published private(set) var changes: [SystemTools.Change] = []
    @Published private(set) var undoing: String?

    init() { reload() }

    func reload() { changes = SystemTools.load() }

    func undo(_ change: SystemTools.Change) {
        guard undoing == nil else { return }
        undoing = change.id
        Task {
            _ = await SystemTools.undo(change)
            undoing = nil
            reload()
        }
    }
}
