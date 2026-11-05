import Foundation
import SwiftUI

/// User settings, kept in UserDefaults.
final class Settings: ObservableObject {
    static let shared: Settings = {
        carryOverFormerSettings()
        return Settings()
    }()

    /// Before 1.6 the app had another name and bundle id: its settings carry over once.
    private static func carryOverFormerSettings() {
        let now = UserDefaults.standard
        guard now.object(forKey: "formerSettingsChecked") == nil else { return }
        now.set(true, forKey: "formerSettingsChecked")
        let formerID = "app.fremen.mac" + "deepseek"
        guard Bundle.main.bundleIdentifier != formerID, let former = UserDefaults(suiteName: formerID)?.persistentDomain(forName: formerID) else { return }
        for (key, value) in former where now.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            now.set(value, forKey: key)
        }
    }

    /// The language of the interface (and of the instructions to the model); at first the Mac's own language.
    @AppStorage("language") var language = AppLanguage.system.rawValue
    @AppStorage("host") var host = "127.0.0.1"
    @AppStorage("port") var port = 8080
    @AppStorage("apiKey") var apiKey = ""
    @AppStorage("contextSize") var contextSize = 65_536
    @AppStorage("vision") var vision = true
    /// The size chosen on the image page, "768x768"; empty: what suits this Mac.
    @AppStorage("imageSize") var imageSize = ""
    @AppStorage("thinking") var thinking = true
    @AppStorage("reasoningEffort") var reasoningEffort = "high"
    /// At most this many tokens of thinking, then the model writes its answer (0: no limit).
    @AppStorage("thinkingBudget") var thinkingBudget = 16_000
    @AppStorage("webSearch") var webSearch = true
    @AppStorage("braveKey") var braveKey = ""
    @AppStorage("temperature") var temperature = 1.0
    @AppStorage("systemPrompt") var systemPrompt = ""
    @AppStorage("autoStart") var autoStart = false
    /// The system check was shown once (the first start opens it).
    @AppStorage("systemCheckSeen") var systemCheckSeen = false
    @AppStorage("modelFolder") var modelFolder = ""
    /// The folder the model may work in (files and commands), and whether that is on.
    @AppStorage("workspace") var workspace = ""
    @AppStorage("workspaceTools") var workspaceTools = true
    /// The project open in the documents module.
    @AppStorage("documentFolder") var documentFolder = ""
    /// The folders of the projects, one per line.
    @AppStorage("documentProjects") var documentProjects = ""
    /// MACAIMAGIC.md in the work folder keeps what the model learned, so it does not make a mistake twice.
    @AppStorage("learnFromChats") var learnFromChats = true
    /// What the model may do in the work folder, per kind of action: "allow", "ask" or "deny".
    @AppStorage("rightRead") var rightRead = "allow"
    @AppStorage("rightWrite") var rightWrite = "ask"
    @AppStorage("rightRun") var rightRun = "ask"
    /// Tests: allow what would be asked.
    @AppStorage("autoApprove") var autoApprove = false

    func right(_ kind: WorkspaceTools.Right) -> String {
        let value = kind == .read ? rightRead : kind == .write ? rightWrite : rightRun
        return value == "ask" && autoApprove ? "allow" : value
    }
    /// Speculative decoding with the model's multi-token prediction head (GLM, Qwen).
    @AppStorage("mtp") var mtp = true
    /// Drifting, brightening background colours (off: a still background, calmer)
    @AppStorage("animatedBackground") var animatedBackground = false
    /// Cluster: "main" (this Mac runs the engine, helpers add memory) or "helper" (this Mac lends its GPU)
    @AppStorage("clusterRole") var clusterRole = "main"
    /// Let a helper listen on the local network too, not only on the Thunderbolt bridge (llama.cpp's RPC has no security)
    @AppStorage("clusterAllowLAN") var clusterAllowLAN = false
}
