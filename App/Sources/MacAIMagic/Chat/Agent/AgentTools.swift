import Foundation

/// What a tool call of phase 5 or 6 needs before it runs.
enum AgentStep: Equatable {
    /// Reading: it runs.
    case run
    /// A change: a card first. `everyTime`: also after "Altijd in dit gesprek" (sending a mail, a click that sends).
    case ask(title: String, detail: String, warnings: [String] = [], everyTime: Bool = false)
    /// Never, with the reason for the model.
    case refuse(String)
}

/// A set of tools of their own (mail, the browser, controlling other apps), switched on in the settings. The chat
/// client asks each call what it needs (`check`), shows a card when it asks, and then runs it.
@MainActor
protocol AgentToolSet: AnyObject {
    var names: Set<String> { get }
    /// Switched on in the settings (and usable on this Mac).
    var isOn: Bool { get }
    var definitions: [[String: Any]] { get }
    var promptSection: String { get }
    /// SF Symbol for the approval card.
    var icon: String { get }
    func label(for call: ToolCall) -> String
    func check(_ call: ToolCall) async -> AgentStep
    func run(_ call: ToolCall) async -> String
}

enum AgentTools {
    /// The sets the chat offers when they are on. Tests put their own here.
    @MainActor static var all: [AgentToolSet] = [MailTools.shared, BrowserTools.shared, ComputerTools.shared]

    @MainActor static func set(for name: String) -> AgentToolSet? { all.first { $0.isOn && $0.names.contains(name) } }

    static func prop(_ type: String, _ description: String) -> [String: Any] { ["type": type, "description": description] }

    static func function(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description,
                      "parameters": ["type": "object", "properties": properties, "required": required] as [String: Any]] as [String: Any]]
    }

    /// Runs an AppleScript with arguments (`on run argv`), so nothing the model writes is ever part of the script.
    /// Off the main thread: Mail can take a while. macOS asks the user once whether MacAIMagic may control the app.
    static func appleScript(_ script: String, _ args: [String] = [], timeout: TimeInterval = 60) async -> (out: String, error: String?) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-"] + args
            let input = Pipe(), out = Pipe(), err = Pipe()
            p.standardInput = input
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch { return ("", error.localizedDescription) }
            input.fileHandleForWriting.write(Data(script.utf8))
            try? input.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(timeout)
            var data = Data()
            let reader = out.fileHandleForReading
            while p.isRunning && Date() < deadline {
                let chunk = reader.availableData
                if chunk.isEmpty { try? await Task.sleep(for: .milliseconds(50)) } else { data.append(chunk) }
            }
            if p.isRunning { p.terminate(); return (String(decoding: data, as: UTF8.self), "timed out after \(Int(timeout)) s") }
            data.append(reader.readDataToEndOfFile())
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    p.terminationStatus == 0 ? nil : (e.isEmpty ? "osascript \(p.terminationStatus)" : e))
        }.value
    }

    /// osascript's error for "not allowed to send Apple events" in plain words.
    static func automationHint(_ error: String, app: String) -> String {
        if error.contains("-1743") || error.lowercased().contains("not allowed") || error.lowercased().contains("niet toegestaan") {
            return "macOS does not allow MacAIMagic to control \(app). Tell the user to allow it in System Settings → Privacy & Security → Automation → MacAIMagic → \(app), then try again."
        }
        return "Error from \(app): \(error)"
    }
}
