import Foundation
import SwiftUI

/// User settings, kept in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    @AppStorage("host") var host = "127.0.0.1"
    @AppStorage("port") var port = 8080
    @AppStorage("apiKey") var apiKey = ""
    @AppStorage("contextSize") var contextSize = 65_536
    @AppStorage("vision") var vision = true
    @AppStorage("thinking") var thinking = true
    @AppStorage("reasoningEffort") var reasoningEffort = "high"
    @AppStorage("webSearch") var webSearch = true
    @AppStorage("braveKey") var braveKey = ""
    @AppStorage("temperature") var temperature = 1.0
    @AppStorage("systemPrompt") var systemPrompt = ""
    @AppStorage("autoStart") var autoStart = false
    @AppStorage("modelFolder") var modelFolder = ""
    /// The folder the model may work in (files and commands), and whether that is on.
    @AppStorage("workspace") var workspace = ""
    @AppStorage("workspaceTools") var workspaceTools = true
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
