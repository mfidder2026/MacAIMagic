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
    /// The model that makes images (Modellen → Kies voor afbeeldingen); empty: the first in the catalog.
    @AppStorage("imageModel") var imageModel = ""
    /// The fast model of the documents module (Modellen → Snel); empty: the smallest that fits beside the heavy one.
    @AppStorage("fastModel") var fastModel = ""
    /// The chat model rewrites the description for the image model first, with the web when it needs it.
    @AppStorage("imageImprove") var imageImprove = false
    @AppStorage("thinking") var thinking = true
    @AppStorage("reasoningEffort") var reasoningEffort = "high"
    /// At most this many tokens of thinking, then the model writes its answer (0: no limit).
    @AppStorage("thinkingBudget") var thinkingBudget = 16_000

    /// Thinking as one choice, the button under the input field. It sets `thinking` and `reasoningEffort`, and it sets
    /// how many tokens the model may think: only some templates read reasoning_effort (DeepSeek), while the engine
    /// stops the thinking of every model at the budget. "high" uses the setting "Maximaal nadenken".
    enum ThinkingLevel: String, CaseIterable, Identifiable {
        case off, low, normal, high
        var id: String { rawValue }
        var name: String {
            switch self {
            case .off: return L("Denken: uit")
            case .low: return L("Denken: laag")
            case .normal: return L("Denken: normaal")
            case .high: return L("Denken: hoog")
            }
        }
        /// Tokens of thinking in an answer's first round; nil: the setting "Maximaal nadenken".
        var budget: Int? {
            switch self {
            case .off: return 0
            case .low: return 2_000
            case .normal: return 8_000
            case .high: return nil
            }
        }
    }

    var thinkingLevel: ThinkingLevel {
        get {
            guard thinking else { return .off }
            switch reasoningEffort {
            case "low": return .low
            case "medium": return .normal
            default: return .high
            }
        }
        set {
            objectWillChange.send()
            thinking = newValue != .off
            switch newValue {
            case .off: break
            case .low: reasoningEffort = "low"
            case .normal: reasoningEffort = "medium"
            case .high: if reasoningEffort != "max" { reasoningEffort = "high" }
            }
        }
    }

    /// How many tokens the model may think in an answer's first round now (0: no limit).
    var thinkingBudgetNow: Int { thinkingLevel.budget ?? thinkingBudget }
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

    /// Instellingen → Systeembeheer, both on by default.
    /// Skills: markdown instructions per subject that the model loads when it needs them.
    @AppStorage("skills") var skills = true
    /// System management: the model reads this Mac's settings and changes them through a plan the user approves.
    @AppStorage("systemManagement") var systemManagement = true
    /// The model knows the app: its help, its state, and actions in it after a card (app_help, app_status, app_action, create_skill).
    @AppStorage("appTools") var appTools = true
    // Instellingen → Taken
    /// The model a task started stops again when the tasks are done and the user did not use it meanwhile.
    @AppStorage("tasksStopModel") var tasksStopModel = true
    @AppStorage("heartbeat") var heartbeat = false
    @AppStorage("heartbeatMinutes") var heartbeatMinutes = 60
    @AppStorage("heartbeatFrom") var heartbeatFrom = 8
    @AppStorage("heartbeatTo") var heartbeatTo = 22
    /// A heartbeat may load the model; off, it only checks while the model is loaded anyway.
    @AppStorage("heartbeatMayLoad") var heartbeatMayLoad = false
    /// With the window closed the app stays in the menu bar while there are tasks or a heartbeat.
    @AppStorage("stayInMenuBar") var stayInMenuBar = true
    /// Closing the window stops the model (unless something is running), so its memory is free again.
    @AppStorage("stopModelOnClose") var stopModelOnClose = true
    // Instellingen → Agent (phases 5 and 6), all off by default
    /// The model reads mail through the Mail app; drafts and sending after a card.
    @AppStorage("featureMail") var featureMail = false
    /// The model browses in a window of its own in MacAIMagic.
    @AppStorage("featureBrowser") var featureBrowser = false
    /// The model controls the apps the user allows (computerApps), every action after a card.
    @AppStorage("featureComputerUse") var featureComputerUse = false
    /// The bundle ids the model may control, one per line.
    @AppStorage("computerApps") var computerApps = ""
    /// Speak in the chat (on this Mac) and read answers aloud.
    @AppStorage("featureVoice") var featureVoice = false
    @AppStorage("speakAnswers") var speakAnswers = false
    @AppStorage("voiceID") var voiceID = ""
    // Instellingen → Telegram
    /// Talk with the model on this Mac through a Telegram bot of your own (off by default).
    @AppStorage("featureTelegram") var featureTelegram = false
    /// Tasks and the heartbeat report in Telegram too, to the first account paired.
    @AppStorage("telegramNotify") var telegramNotify = true
    /// Reading the system (diagnosis) and changing it: "allow", "ask" or "deny". Admin changes always ask.
    @AppStorage("rightSystemRead") var rightSystemRead = "allow"
    @AppStorage("rightSystemChange") var rightSystemChange = "ask"

    func systemRight(change: Bool) -> String {
        let value = change ? rightSystemChange : rightSystemRead
        return value == "ask" && autoApprove ? "allow" : value
    }

    func right(_ kind: WorkspaceTools.Right) -> String {
        let value = kind == .read ? rightRead : kind == .write ? rightWrite : rightRun
        return value == "ask" && autoApprove ? "allow" : value
    }
    /// Speculative decoding with the model's multi-token prediction head (GLM, Qwen).
    @AppStorage("mtp") var mtp = true
    /// Save a conversation's place in the engine when another one takes it or the engine stops, and read it back
    /// (SlotKeeper): continuing a long conversation then does not read it all again.
    @AppStorage("keepEngineMemory") var keepEngineMemory = true
    /// Drifting, brightening background colours (off: a still background, calmer)
    @AppStorage("animatedBackground") var animatedBackground = false
    /// Cluster: "main" (this Mac runs the engine, helpers add memory) or "helper" (this Mac lends its GPU)
    @AppStorage("clusterRole") var clusterRole = "main"
    /// Let a helper listen on the local network too, not only on the Thunderbolt bridge (llama.cpp's RPC has no security)
    @AppStorage("clusterAllowLAN") var clusterAllowLAN = false
}
