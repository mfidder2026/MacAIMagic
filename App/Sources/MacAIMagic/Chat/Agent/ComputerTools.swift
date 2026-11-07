import Foundation
import AppKit
import ApplicationServices

/// Controlling other apps (phase 6): only the apps the user allows (Instellingen → Agent), through the accessibility
/// tree of their window: the model sees numbered buttons, fields and menus, and presses, types or sends keys. Every
/// action shows a card (unless "Altijd in dit gesprek"); one that sends, pays or deletes asks every time. Never in a
/// password field, and never in apps that hold passwords or the Mac's security settings.
@MainActor
final class ComputerTools: AgentToolSet {
    static let shared = ComputerTools()

    let names: Set<String> = ["computer_apps", "computer_look", "computer_click", "computer_type", "computer_key"]
    var isOn: Bool { Settings.shared.featureComputerUse || forTests }
    let icon = "cursorarrow.click.2"
    var forTests = false

    /// Apps that are never controlled, whatever the list says: passwords, keys, security, payments.
    nonisolated static let never: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences", "com.apple.SecurityAgent",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.apple.ScriptEditor2", "app.fremen.macaimagic",
    ]

    /// The apps the user allows, by bundle id.
    var allowed: [String] {
        Settings.shared.computerApps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !Self.never.contains($0) }
    }

    func allow(_ bundleID: String) {
        guard !Self.never.contains(bundleID), !allowed.contains(bundleID) else { return }
        Settings.shared.computerApps = (allowed + [bundleID]).joined(separator: "\n")
    }

    func disallow(_ bundleID: String) {
        Settings.shared.computerApps = allowed.filter { $0 != bundleID }.joined(separator: "\n")
    }

    var definitions: [[String: Any]] {
        func f(_ n: String, _ d: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] { AgentTools.function(n, d, props, required: required) }
        func p(_ t: String, _ d: String) -> [String: Any] { AgentTools.prop(t, d) }
        return [
            f("computer_apps", "The apps you may control on this Mac (the user chose them), with their ids and whether they run. Read-only."),
            f("computer_look", "Look at an allowed app: it is opened if needed, and you get its window title and the numbered buttons, fields, menus and texts in its front window. Read-only.",
              ["app": p("string", "The app's id or name from computer_apps")], required: ["app"]),
            f("computer_click", "Press a button, checkbox, menu item or other element by its number from computer_look. The user approves it first.",
              ["app": p("string", "The app's id or name"), "element": p("integer", "The element's number")], required: ["app", "element"]),
            f("computer_type", "Put text into a text field by its number from computer_look. Never a password field. The user approves it first.",
              ["app": p("string", "The app's id or name"), "element": p("integer", "The field's number"), "text": p("string", "The text")],
              required: ["app", "element", "text"]),
            f("computer_key", "Press a key or key combination in an allowed app, e.g. return, escape, tab, cmd+s, cmd+shift+n. The user approves it first.",
              ["app": p("string", "The app's id or name"), "keys": p("string", "The keys")], required: ["app", "keys"]),
        ]
    }

    var promptSection: String {
        L("Je kunt apps op deze Mac besturen die de gebruiker heeft toegestaan: computer_apps geeft de lijst, computer_look laat de genummerde knoppen, velden en menu's van het venster zien, en computer_click, computer_type en computer_key doen een handeling. Kijk na elke handeling opnieuw met computer_look. Elke handeling vraagt eerst toestemming. Typ nooit wachtwoorden en doe geen betalingen.")
    }

    func label(for call: ToolCall) -> String {
        let a = WorkspaceTools.args(call)
        let app = a["app"] as? String ?? ""
        switch call.name {
        case "computer_apps": return L("Apps bekijken")
        case "computer_look": return L("Kijken in \(appName(app))")
        case "computer_click": return L("Klik in \(appName(app))")
        case "computer_type": return L("Typen in \(appName(app))")
        default: return L("Toetsen in \(appName(app)): \(a["keys"] as? String ?? "")")
        }
    }

    // MARK: - apps

    private func appName(_ idOrName: String) -> String {
        resolve(idOrName).flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? idOrName
    }

    /// An allowed app's bundle id from its id or its name.
    func resolve(_ idOrName: String) -> String? {
        let want = idOrName.trimmingCharacters(in: .whitespaces).lowercased()
        return allowed.first { id in
            id.lowercased() == want || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "").lowercased() == want } == true
        }
    }

    // MARK: - the accessibility tree

    struct Item: Equatable {
        let n: Int
        let role: String
        let title: String
        let value: String
        let enabled: Bool
        var secure: Bool { role == "AXSecureTextField" }
        var isText: Bool { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) }
    }
    private var items: [String: [Int: (Item, AXUIElement)]] = [:]

    nonisolated static func trusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func text(_ e: AXUIElement, _ name: String) -> String {
        guard let v = attr(e, name) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// The roles worth showing: what can be pressed or typed in, and the texts that say where one is.
    nonisolated static let shown: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox", "AXSearchField", "AXLink", "AXTab", "AXCell",
        "AXRow", "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXStaticText", "AXHeading", "AXImage",
    ]

    private func look(_ bundleID: String) async -> String {
        guard Self.trusted(prompt: true) else {
            return "macOS does not allow MacAIMagic to control other apps yet. Tell the user to switch MacAIMagic on in System Settings → Privacy & Security → Accessibility, then try again."
        }
        var app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if app == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            try? await Task.sleep(for: .seconds(2))
        }
        guard let app else { return "That app is not on this Mac." }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (Self.attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        let window = (Self.attr(root, kAXFocusedWindowAttribute)).map { $0 as! AXUIElement } ?? windows.first
        var found: [(Item, AXUIElement)] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 30, found.count < 300 else { return }
            let role = Self.text(e, kAXRoleAttribute)
            if Self.shown.contains(role) {
                var title = Self.text(e, kAXTitleAttribute)
                if title.isEmpty { title = Self.text(e, kAXDescriptionAttribute) }
                if title.isEmpty { title = Self.text(e, kAXHelpAttribute) }
                let value = role == "AXSecureTextField" ? "" : Self.text(e, kAXValueAttribute)
                let enabled = (Self.attr(e, kAXEnabledAttribute) as? Bool) ?? true
                // a text without words, an image without a name: nothing to go by
                if !(role == "AXStaticText" && value.isEmpty && title.isEmpty) && !(role == "AXImage" && title.isEmpty) {
                    found.append((Item(n: found.count + 1, role: role, title: String(title.prefix(80)), value: String(value.prefix(120)), enabled: enabled), e))
                }
            }
            for child in (Self.attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: depth + 1) }
        }
        if let window { walk(window, depth: 0) }
        // the menu bar's top items, so the model can reach a command
        if let bar = Self.attr(root, kAXMenuBarAttribute) {
            for item in (Self.attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                let title = Self.text(item, kAXTitleAttribute)
                if !title.isEmpty && title != "Apple" { found.append((Item(n: found.count + 1, role: "AXMenuBarItem", title: title, value: "", enabled: true), item)) }
            }
        }
        items[bundleID] = Dictionary(uniqueKeysWithValues: found.map { ($0.0.n, $0) })
        let name = app.localizedName ?? bundleID
        let title = window.map { Self.text($0, kAXTitleAttribute) } ?? ""
        let lines = found.map { pair -> String in
            let i = pair.0
            var line = "[\(i.n)] \(i.role.replacingOccurrences(of: "AX", with: ""))"
            if !i.title.isEmpty { line += " \"\(i.title)\"" }
            if !i.value.isEmpty { line += " = \"\(i.value)\"" }
            if !i.enabled { line += " (disabled)" }
            if i.secure { line += " (password field: the user types here)" }
            return line
        }
        return "\(name), window \"\(title)\"\(window == nil ? " (no window open)" : "")\n" + lines.joined(separator: "\n")
    }

    // MARK: - checks

    func check(_ call: ToolCall) async -> AgentStep {
        let a = WorkspaceTools.args(call)
        if call.name == "computer_apps" { return .run }
        guard let id = resolve(a["app"] as? String ?? "") else {
            return .refuse("That app is not allowed. The allowed apps: \(allowed.joined(separator: ", ")). The user adds apps in Settings → Agent.")
        }
        if call.name == "computer_look" { return .run }
        let name = appName(id)
        if call.name == "computer_key" {
            let keys = (a["keys"] as? String ?? "").lowercased()
            guard Self.keyCode(keys) != nil else { return .refuse("Error: unknown keys '\(keys)'. Use e.g. return, escape, tab, cmd+s.") }
            let risky = ["return", "enter", "cmd+return", "cmd+enter", "cmd+shift+d", "cmd+delete", "cmd+backspace"].contains(keys)
            return .ask(title: L("Toetsen in \(name): \(keys)"), detail: keys,
                        warnings: risky ? [L("Deze toets kan iets versturen of verwijderen.")] : [], everyTime: risky)
        }
        guard let (item, _) = items[id]?[BrowserTools.int(a["element"])] else {
            return .refuse("There is no element with that number. Use computer_look first for the current numbers.")
        }
        let what = item.title.isEmpty ? item.role.replacingOccurrences(of: "AX", with: "") : "\"\(item.title)\""
        if call.name == "computer_type" {
            if item.secure { return .refuse("That is a password field. You never type passwords: ask the user to type it themselves.") }
            guard item.isText else { return .refuse("Element \(item.n) is no text field (\(item.role)).") }
            return .ask(title: L("Typen in \(name): \(what)"), detail: a["text"] as? String ?? "")
        }
        let risky = item.title.range(of: BrowserTools.risky, options: .regularExpression) != nil
        return .ask(title: L("Klik in \(name): \(what)"), detail: item.role.replacingOccurrences(of: "AX", with: "") + (item.value.isEmpty ? "" : " = " + item.value),
                    warnings: risky ? [L("Deze knop verstuurt, koopt, plaatst of verwijdert misschien iets.")] : [], everyTime: risky)
    }

    // MARK: - running

    func run(_ call: ToolCall) async -> String {
        let a = WorkspaceTools.args(call)
        if call.name == "computer_apps" {
            guard !allowed.isEmpty else { return "The user has not allowed any app yet. They add apps in Settings → Agent." }
            return allowed.map { id in
                let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
                return "\(appName(id)) (\(id))\(running ? ", running" : "")"
            }.joined(separator: "\n")
        }
        guard let id = resolve(a["app"] as? String ?? "") else { return "That app is not allowed." }
        if call.name == "computer_look" { return await look(id) }
        guard Self.trusted(prompt: false) else { return "macOS does not allow MacAIMagic to control other apps (Accessibility)." }
        if call.name == "computer_key" {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                  let (code, flags) = Self.keyCode((a["keys"] as? String ?? "").lowercased()) else { return "The app does not run, or the keys are unknown." }
            app.activate()
            try? await Task.sleep(for: .milliseconds(300))
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                e?.flags = flags
                e?.postToPid(app.processIdentifier)
            }
            try? await Task.sleep(for: .milliseconds(500))
            return "Pressed \(a["keys"] as? String ?? ""). Use computer_look to see the result."
        }
        guard let (item, element) = items[id]?[BrowserTools.int(a["element"])] else { return "The element is gone. Use computer_look." }
        if call.name == "computer_type" {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let r = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, (a["text"] as? String ?? "") as CFString)
            return r == .success ? "Typed into \(item.title.isEmpty ? "field \(item.n)" : item.title). Use computer_look to check." : "The field did not take the text (\(r.rawValue))."
        }
        let r = AXUIElementPerformAction(element, (item.role == "AXMenuBarItem" || item.role == "AXMenuButton" || item.role == "AXPopUpButton" ? kAXShowMenuAction : kAXPressAction) as CFString)
        try? await Task.sleep(for: .milliseconds(600))
        return r == .success ? "Pressed. Use computer_look to see the result." : "It could not be pressed (\(r.rawValue)); try another element or computer_key."
    }

    // MARK: - keys

    nonisolated static let codes: [String: CGKeyCode] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ",": 43, ".": 47, "/": 44,
    ]

    /// "cmd+shift+n" → the key code and the modifiers; nil for a key it does not know.
    nonisolated static func keyCode(_ keys: String) -> (CGKeyCode, CGEventFlags)? {
        var parts = keys.replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let key = parts.popLast(), let code = codes[key] else { return nil }
        var flags: CGEventFlags = []
        for m in parts {
            switch m {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: return nil
            }
        }
        // quitting or logging out is not something to do for the user
        if flags.contains(.maskCommand) && key == "q" { return nil }
        return (code, flags)
    }
}
