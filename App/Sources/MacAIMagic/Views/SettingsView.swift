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
                    Picker(L("Maximaal nadenken"), selection: $settings.thinkingBudget) {
                        ForEach([4_000, 8_000, 16_000, 32_000], id: \.self) { Text(L("\($0.formatted()) tokens")).tag($0) }
                        Text(L("Onbeperkt")).tag(0)
                    }
                    Text(L("Geldt voor Denken: hoog. Daarna schrijft het model zijn antwoord. Zonder grens kan een model bij een lastige vraag blijven twijfelen en nooit antwoorden. Laag is 2.000 tokens, normaal 8.000."))
                        .font(.caption).foregroundStyle(.secondary)
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
                    Toggle(L("Bewaar wat het model leert in MACAIMAGIC.md, zodat het fouten niet twee keer maakt"), isOn: $settings.learnFromChats)
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
                    Toggle(L("Herhaalde tekst sneller schrijven"), isOn: $settings.ngramMod)
                        .disabled(!settings.mtp)
                    Text(L("Neemt het model tekst over die al in het gesprek staat, zoals code die het aanpast of een bestand dat het herschrijft, dan schrijft het die in grote stukken tegelijk: tot twee keer zo snel. Het antwoord blijft hetzelfde. Werkt samen met MTP en geldt na het herstarten van de engine."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Gesprekken in de engine bewaren"), isOn: $settings.keepEngineMemory)
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("Wat de engine van een gesprek gelezen heeft, gaat naar de SSD als een ander gesprek of een taak het model krijgt, of als de engine stopt. Verder gaan leest het dan niet opnieuw: bij DeepSeek scheelt dat minuten. Hooguit 40 GB, de oudste gaan eerst."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Wis (\(SlotKeeper.usedText))")) { SlotKeeper.clearAll() }.controlSize(.small)
                    }
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

            Form {
                Section {
                    HStack {
                        Text(L("Het model kan deze Mac voor je bekijken en instellen. Een wijziging keur je eerst goed, en het model kan hem weer ongedaan maken."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        HelpButton(topic: "sysadmin")
                    }
                }
                Section(L("Skills")) {
                    Toggle(L("Skills: instructies per onderwerp, met geteste commando's"), isOn: $settings.skills)
                    HStack {
                        Text(L("Eigen skills: een map met een SKILL.md erin. Een eigen skill met dezelfde naam vervangt de ingebouwde."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Open map")) {
                            try? FileManager.default.createDirectory(at: Paths.userSkills, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(Paths.userSkills)
                        }
                    }
                }
                Section(L("De app")) {
                    Toggle(L("Het model kent de app en mag er dingen in doen"), isOn: $settings.appTools)
                    Text(L("Het model leest de hulp en de stand van de app, en doet wat je vraagt: een model downloaden of kiezen, de engine starten, een instelling wijzigen, een scherm openen, een skill maken. Een wijziging komt eerst op een kaart; een model verwijderen vraagt altijd. Zijn eigen rechten en sleutels kan het niet wijzigen."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("Deze Mac")) {
                    Toggle(L("Het model mag deze Mac bekijken en instellen"), isOn: $settings.systemManagement)
                    Picker(L("Systeem lezen (diagnose)"), selection: $settings.rightSystemRead) { rightOptions }
                    Picker(L("Systeem wijzigen (een plan dat je goedkeurt)"), selection: $settings.rightSystemChange) { rightOptions }
                    Text(L("Wijzigingen met beheerdersrechten vragen altijd eerst, en daarna vraagt macOS om je wachtwoord. Gevoelige instellingen krijgen een waarschuwing. Vraag het model om een wijziging ongedaan te maken."))
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.rightSystemChange == "allow" {
                        Text(L("Let op: het model kan dan zonder te vragen instellingen van je gebruiker wijzigen."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .tabItem { Label(L("Systeembeheer"), systemImage: "gearshape.2") }

            ConnectorsView()
                .tabItem { Label(L("Connectors"), systemImage: "puzzlepiece.extension") }

            TasksSettingsView()
                .tabItem { Label(L("Taken"), systemImage: "clock.badge.checkmark") }

            AgentSettingsView()
                .tabItem { Label(L("Agent"), systemImage: "wand.and.stars") }

            TelegramSettingsView()
                .tabItem { Label(L("Telegram"), systemImage: "paperplane") }
        }
        .formStyle(.grouped)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 600, idealHeight: 700)
    }

    @ViewBuilder private var rightOptions: some View {
        Text(L("Toestaan")).tag("allow")
        Text(L("Eerst vragen")).tag("ask")
        Text(L("Weigeren")).tag("deny")
    }
}
