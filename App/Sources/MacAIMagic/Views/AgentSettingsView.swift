import SwiftUI
import AppKit
import AVFoundation

/// Instellingen → Agent: mail, the browser, controlling other apps, and speech. All off by default.
struct AgentSettingsView: View {
    @EnvironmentObject var settings: Settings
    @State private var apps: [String] = ComputerTools.shared.allowed
    @State private var axTrusted = ComputerTools.trusted(prompt: false)

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(L("Laat het model ook buiten de chat werken: je e-mail lezen, op websites werken, andere apps bedienen en praten. Alles staat standaard uit, en elke wijziging komt eerst op een kaart."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HelpButton(topic: "agent")
                }
            }

            Section(L("E-mail")) {
                Toggle(L("E-mail via de Mail-app"), isOn: $settings.featureMail)
                Text(L("Het model leest, zoekt en vat je mail samen in de accounts van de Mail-app; MacAIMagic krijgt geen wachtwoord. Een concept opent in Mail na een kaart; versturen vraagt altijd, ook na 'Altijd in dit gesprek'. macOS vraagt de eerste keer of MacAIMagic Mail mag bedienen."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Browser")) {
                Toggle(L("Browser in een eigen venster"), isOn: $settings.featureBrowser)
                Text(L("Het model surft in een eigen venster van MacAIMagic dat je kunt meekijken, met eigen cookies, los van Safari en Chrome. Inloggen doe je zelf in dat venster. Een klik op een knop vraagt eerst; versturen, kopen, plaatsen of verwijderen vraagt elke keer. Wachtwoord- en betaalvelden vult het model nooit in."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("Apps besturen")) {
                Toggle(L("Het model mag deze apps besturen"), isOn: $settings.featureComputerUse)
                if settings.featureComputerUse && !axTrusted {
                    HStack {
                        Label(L("macOS moet MacAIMagic eerst toegang geven (Toegankelijkheid)."), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                        Spacer()
                        Button(L("Vraag toegang")) { axTrusted = ComputerTools.trusted(prompt: true) }
                    }
                }
                ForEach(apps, id: \.self) { id in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Text(id)
                        }
                        Spacer()
                        Button(L("Verwijder")) { ComputerTools.shared.disallow(id); apps = ComputerTools.shared.allowed }
                    }
                }
                Button(L("App toevoegen…")) { addApp() }
                Text(L("Het model ziet de knoppen, velden en menu's van het venster en drukt, typt of geeft toetsen, elke keer na een kaart. Wachtwoordvelden, Sleutelhanger, Wachtwoorden, Systeeminstellingen, Terminal en wachtwoordmanagers zijn nooit toegestaan."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { axTrusted = ComputerTools.trusted(prompt: false) }

            Section(L("Spraak")) {
                Toggle(L("Spraak (inspreken en voorlezen)"), isOn: $settings.featureVoice)
                Toggle(L("Lees antwoorden vanzelf voor"), isOn: $settings.speakAnswers)
                    .disabled(!settings.featureVoice)
                Picker(L("Stem"), selection: $settings.voiceID) {
                    Text(L("Standaard")).tag("")
                    ForEach(Voice.voices, id: \.identifier) { v in
                        Text(v.name + (v.quality == .premium ? " (premium)" : v.quality == .enhanced ? " (" + L("verbeterd") + ")" : "")).tag(v.identifier)
                    }
                }
                .disabled(!settings.featureVoice)
                Text(L("Met de microfoon naast het invoerveld spreek je een vraag in; de herkenning gebeurt op deze Mac. De luidspreker onder een antwoord leest het voor. Spraakberichten in Telegram worden ook op de Mac tekst. Betere stemmen download je in Systeeminstellingen → Toegankelijkheid → Gesproken materiaal."))
                    .font(.caption).foregroundStyle(.secondary)
                Label(L("Werkt de microfoon niet, zet dan Dicteren aan in Systeeminstellingen → Toetsenbord → Dicteren. Op macOS 26 en nieuwer gebruikt MacAIMagic de nieuwere spraakherkenning van Apple; macOS downloadt de taal de eerste keer."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var refused: [String] = []
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            if ComputerTools.never.contains(id) { refused.append(FileManager.default.displayName(atPath: url.path)) } else { ComputerTools.shared.allow(id) }
        }
        apps = ComputerTools.shared.allowed
        if !refused.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Niet toegestaan")
            alert.informativeText = L("Deze apps bevatten wachtwoorden of beveiliging en mag het model nooit besturen: \(refused.joined(separator: ", ")).")
            alert.runModal()
        }
    }
}
