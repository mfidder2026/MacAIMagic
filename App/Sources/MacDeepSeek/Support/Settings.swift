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
}
