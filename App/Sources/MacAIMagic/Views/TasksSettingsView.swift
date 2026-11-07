import SwiftUI
import AppKit
import ServiceManagement

/// Instellingen → Taken: the heartbeat, and what the model does around tasks.
struct TasksSettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: Settings
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginProblem: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(L("De heartbeat laat het model af en toe een checklist nalopen, bijvoorbeeld je agenda of de schijf. Het meldt zich alleen als er iets is."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HelpButton(topic: "tasks")
                }
                Toggle(L("Heartbeat"), isOn: $settings.heartbeat)
                Picker(L("Hoe vaak"), selection: $settings.heartbeatMinutes) {
                    Text(L("Elk half uur")).tag(30)
                    Text(L("Elk uur")).tag(60)
                    Text(L("Elke 2 uur")).tag(120)
                    Text(L("Elke 4 uur")).tag(240)
                }
                .disabled(!settings.heartbeat)
                HStack {
                    Picker(L("Van"), selection: $settings.heartbeatFrom) { hours }
                    Picker(L("Tot"), selection: $settings.heartbeatTo) { hours }
                }
                .disabled(!settings.heartbeat)
                Toggle(L("Het model mag hiervoor laden"), isOn: $settings.heartbeatMayLoad)
                    .disabled(!settings.heartbeat)
                Text(settings.heartbeatMayLoad
                     ? L("Is het model niet geladen, dan laadt de heartbeat het en stopt het daarna weer. Dat kost bij een groot model elke keer een paar minuten en veel stroom.")
                     : L("Is het model niet geladen, dan slaat de heartbeat over."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Open checklist")) {
                        _ = Heartbeat.checklist()
                        NSWorkspace.shared.open(Paths.heartbeat)
                    }
                    Button(L("Nu controleren")) { Task { await app.heartbeat(forced: true) } }
                        .disabled(!app.engine.state.isRunning && !app.canStart)
                    Spacer()
                    if let status = app.heartbeatStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section(L("Op de achtergrond")) {
                Toggle(L("In de menubalk blijven als het venster dicht is"), isOn: $settings.stayInMenuBar)
                Text(L("Alleen als er taken of een heartbeat aan staan. Dan kunnen ze doorgaan met het venster dicht; MacAIMagic staat dan rechtsboven in de menubalk."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Het model stoppen als het venster dicht gaat"), isOn: $settings.stopModelOnClose)
                    .disabled(!settings.stayInMenuBar)
                Toggle(L("Start bij inloggen"), isOn: Binding(get: { atLogin }, set: { on in setLogin(on) }))
                if let loginProblem { Text(loginProblem).font(.caption).foregroundStyle(.orange) }
                if SMAppService.mainApp.status == .requiresApproval {
                    Text(L("macOS wil dit eerst laten goedkeuren: Systeeminstellingen → Algemeen → Inloggen.")).font(.caption).foregroundStyle(.orange)
                }
            }
            Section(L("Taken")) {
                Toggle(L("Het model na een taak weer stoppen"), isOn: $settings.tasksStopModel)
                Text(L("Als een taak het model laadde en jij het intussen niet gebruikte, stopt het weer als de taken klaar zijn, zodat het geheugen vrij is."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginProblem = nil
        } catch {
            loginProblem = L("Dat lukte niet: \(error.localizedDescription)")
        }
        atLogin = SMAppService.mainApp.status == .enabled
    }

    @ViewBuilder private var hours: some View {
        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
    }
}
