import SwiftUI

/// Under Systeem: what the model changed on this Mac (Instellingen → Experimenteel → Systeembeheer), with undo.
struct ChangesSection: View {
    @ObservedObject var log = ChangeLog.shared
    @ObservedObject var settings = Settings.shared
    @State private var confirm: SystemTools.Change?

    var body: some View {
        if settings.featureSystem || !log.changes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Wijzigingen door het model")).font(.system(.title3, design: .rounded).bold())
                    Spacer()
                    Button(L("Map openen")) {
                        try? FileManager.default.createDirectory(at: Paths.changes, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Paths.changes)
                    }
                    Button { log.reload() } label: { Image(systemName: "arrow.clockwise") }.help(L("Vernieuwen"))
                }
                GlassCard(glow: Theme.accent) {
                    if log.changes.isEmpty {
                        Text(L("Nog geen wijzigingen. Vraag in de chat bijvoorbeeld: \"Zet het Dock links\" of \"Waarom is mijn Mac traag?\""))
                            .foregroundStyle(.secondary).padding(.vertical, 10)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(log.changes.prefix(30).enumerated()), id: \.element.id) { i, c in
                                if i > 0 { Divider().opacity(0.4) }
                                row(c)
                            }
                        }
                    }
                }
            }
            .alert(L("Wijziging ongedaan maken?"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button(L("Annuleren"), role: .cancel) { confirm = nil }
                Button(L("Ongedaan maken")) { if let c = confirm { log.undo(c) }; confirm = nil }
            } message: {
                Text(confirm.map { L("\($0.summary)\n\nDe stappen worden in omgekeerde volgorde teruggezet.") + ($0.admin ? "\n" + L("macOS vraagt daarvoor om je wachtwoord.") : "") } ?? "")
            }
        }
    }

    private func row(_ c: SystemTools.Change) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: c.undone != nil ? "arrow.uturn.backward.circle.fill" : c.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(c.undone != nil ? Color.secondary : c.succeeded ? Theme.mint : Theme.amber)
                .font(.system(size: 17)).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.summary).font(.headline)
                Text(c.date.formatted(date: .abbreviated, time: .shortened) + (c.admin ? " · " + L("beheerder") : "") + (c.snapshot ? " · " + L("met snapshot") : ""))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(c.steps.enumerated()), id: \.offset) { i, s in
                    let r = c.results[i]
                    Text("\(i + 1). \(s.title)" + (r.ran ? (r.ok ? "" : " — " + L("mislukt")) : " — " + L("niet uitgevoerd")))
                        .font(.callout).foregroundStyle(r.ran && !r.ok ? Theme.amber : .secondary)
                }
                if let undone = c.undone {
                    Text(L("Ongedaan gemaakt op \(undone.formatted(date: .abbreviated, time: .shortened))")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if c.undone == nil && c.results.contains(where: \.ran) {
                if log.undoing == c.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("Ongedaan maken")) { confirm = c }.disabled(log.undoing != nil)
                }
            }
        }
        .padding(.vertical, 10)
    }
}
