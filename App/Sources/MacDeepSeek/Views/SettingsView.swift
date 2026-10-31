import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        TabView {
            Form {
                Section("Antwoorden") {
                    Picker("Denkniveau", selection: $settings.reasoningEffort) {
                        Text("Laag").tag("low"); Text("Gemiddeld").tag("medium")
                        Text("Hoog").tag("high"); Text("Maximaal").tag("max")
                    }
                    Slider(value: $settings.temperature, in: 0...1.5, step: 0.1) {
                        Text("Temperatuur \(settings.temperature, specifier: "%.1f")")
                    }
                    TextField("Systeemprompt", text: $settings.systemPrompt, axis: .vertical).lineLimit(3...8)
                }
                Section("Web zoeken") {
                    SecureField("Brave Search API-sleutel (optioneel)", text: $settings.braveKey)
                    Text("Zonder sleutel zoekt MacDeepSeek via DuckDuckGo.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }

            Form {
                Section("Model") {
                    Picker("Context", selection: $settings.contextSize) {
                        Text("32K").tag(32_768); Text("64K").tag(65_536)
                        Text("128K").tag(131_072); Text("256K").tag(262_144)
                    }
                    Toggle("Afbeeldingen (vision, 1 GB extra)", isOn: $settings.vision)
                    Toggle("Engine starten bij openen app", isOn: $settings.autoStart)
                }
                Section("Server") {
                    TextField("Adres", text: $settings.host)
                    TextField("Poort", value: $settings.port, format: .number.grouping(.never))
                    SecureField("API-sleutel (leeg = alleen deze Mac)", text: $settings.apiKey)
                    Text("Wijzigingen gelden na het herstarten van de engine. Gebruik 0.0.0.0 alleen met een API-sleutel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Engine", systemImage: "cpu") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
    }
}
