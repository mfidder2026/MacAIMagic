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
                    HStack {
                        Text("Algemene notities voor het model (MACDEEPSEEK.md), in elk gesprek. Een werkmap kan er een eigen MACDEEPSEEK.md bij hebben.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open bestand") {
                            let url = Paths.generalNotes
                            if !FileManager.default.fileExists(atPath: url.path) {
                                try? "# Notities voor het model\n\nSchrijf hier wat het model in elk gesprek moet weten.\n".write(to: url, atomically: true, encoding: .utf8)
                            }
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Section("Werkmap") {
                    Toggle("Bestanden en commando's in de werkmap", isOn: $settings.workspaceTools)
                    Picker("Lezen (mappen en bestanden)", selection: $settings.rightRead) { rightOptions }
                    Picker("Schrijven (bestanden maken en aanpassen)", selection: $settings.rightWrite) { rightOptions }
                    Picker("Uitvoeren (commando's, scripts, apps)", selection: $settings.rightRun) { rightOptions }
                    if settings.rightWrite == "allow" || settings.rightRun == "allow" {
                        Text("Let op: het model kan dan zonder te vragen bestanden in de werkmap wijzigen of commando's uitvoeren.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(settings.workspace.isEmpty ? "Nog geen werkmap gekozen (knop in de chat)." : settings.workspace)
                        .font(.caption).foregroundStyle(.secondary)
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
                        Text("512K").tag(524_288); Text("1M").tag(1_048_576)
                    }
                    Text("Meer context kost geheugen (KV-cache): bij 1M ~6 GB voor DeepSeek, ~20 GB voor GLM. Qwen gaat tot 256K. Een vol gesprek wordt automatisch samengevat.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Afbeeldingen (vision, 1 GB extra)", isOn: $settings.vision)
                    Toggle("Sneller schrijven met MTP (GLM en Qwen)", isOn: $settings.mtp)
                    Toggle("Engine starten bij openen app", isOn: $settings.autoStart)
                    Toggle("Bewegende achtergrond", isOn: $settings.animatedBackground)
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
        .frame(width: 560, height: 520)
    }

    @ViewBuilder private var rightOptions: some View {
        Text("Toestaan").tag("allow")
        Text("Eerst vragen").tag("ask")
        Text("Weigeren").tag("deny")
    }
}
