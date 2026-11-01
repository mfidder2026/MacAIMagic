import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings

    var body: some View {
        TabView {
            Form {
                Section(L("Taal")) {
                    Picker(L("Taal van de app"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Text(L("Ook het model krijgt zijn instructies in deze taal."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Antwoorden")) {
                    Picker(L("Denkniveau"), selection: $settings.reasoningEffort) {
                        Text(L("Laag")).tag("low"); Text(L("Gemiddeld")).tag("medium")
                        Text(L("Hoog")).tag("high"); Text(L("Maximaal")).tag("max")
                    }
                    Slider(value: $settings.temperature, in: 0...1.5, step: 0.1) {
                        Text(L("Temperatuur \(settings.temperature, specifier: "%.1f")"))
                    }
                    TextField(L("Systeemprompt"), text: $settings.systemPrompt, axis: .vertical).lineLimit(3...8)
                    HStack {
                        Text(L("Algemene notities voor het model (MACAIMAGIC.md), in elk gesprek. Een werkmap kan er een eigen MACAIMAGIC.md bij hebben."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Open bestand")) {
                            let url = Paths.generalNotes
                            if !FileManager.default.fileExists(atPath: url.path) {
                                try? L("# Notities voor het model\n\nSchrijf hier wat het model in elk gesprek moet weten.\n").write(to: url, atomically: true, encoding: .utf8)
                            }
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Section(L("Werkmap")) {
                    Toggle(L("Bestanden en commando's in de werkmap"), isOn: $settings.workspaceTools)
                    Picker(L("Lezen (mappen en bestanden)"), selection: $settings.rightRead) { rightOptions }
                    Picker(L("Schrijven (bestanden maken en aanpassen)"), selection: $settings.rightWrite) { rightOptions }
                    Picker(L("Uitvoeren (commando's, scripts, apps)"), selection: $settings.rightRun) { rightOptions }
                    if settings.rightWrite == "allow" || settings.rightRun == "allow" {
                        Text(L("Let op: het model kan dan zonder te vragen bestanden in de werkmap wijzigen of commando's uitvoeren."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text(settings.workspace.isEmpty ? L("Nog geen werkmap gekozen (knop in de chat).") : settings.workspace)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Web zoeken")) {
                    SecureField(L("Brave Search API-sleutel (optioneel)"), text: $settings.braveKey)
                    Text(L("Zonder sleutel zoekt MacAIMagic via DuckDuckGo.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label(L("Chat"), systemImage: "bubble.left.and.bubble.right") }

            Form {
                Section(L("Model")) {
                    Picker(L("Context"), selection: $settings.contextSize) {
                        Text("32K").tag(32_768); Text("64K").tag(65_536)
                        Text("128K").tag(131_072); Text("256K").tag(262_144)
                        Text("512K").tag(524_288); Text("1M").tag(1_048_576)
                    }
                    Text(L("Meer context kost geheugen (KV-cache): bij 1M ~6 GB voor DeepSeek, ~20 GB voor GLM. Qwen gaat tot 256K. Een vol gesprek wordt automatisch samengevat."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Afbeeldingen (vision, 1 GB extra)"), isOn: $settings.vision)
                    Toggle(L("Sneller schrijven met MTP (GLM en Qwen)"), isOn: $settings.mtp)
                    Toggle(L("Engine starten bij openen app"), isOn: $settings.autoStart)
                    Toggle(L("Bewegende achtergrond"), isOn: $settings.animatedBackground)
                }
                Section(L("Server")) {
                    TextField(L("Adres"), text: $settings.host)
                    TextField(L("Poort"), value: $settings.port, format: .number.grouping(.never))
                    SecureField(L("API-sleutel (leeg = alleen deze Mac)"), text: $settings.apiKey)
                    Text(L("Wijzigingen gelden na het herstarten van de engine. Gebruik 0.0.0.0 alleen met een API-sleutel."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label(L("Engine"), systemImage: "cpu") }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }

    @ViewBuilder private var rightOptions: some View {
        Text(L("Toestaan")).tag("allow")
        Text(L("Eerst vragen")).tag("ask")
        Text(L("Weigeren")).tag("deny")
    }
}
