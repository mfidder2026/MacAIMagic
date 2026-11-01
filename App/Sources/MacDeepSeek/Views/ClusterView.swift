import SwiftUI

/// Several Macs as one memory: choose this Mac's role, see the helpers, and what the model gains from them.
struct ClusterView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cluster: ClusterController
    @EnvironmentObject var settings: Settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cluster").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Verbind meerdere Macs met Thunderbolt en gebruik hun geheugen samen voor één groot model.")
                            .foregroundStyle(.secondary)
                    }
                }

                GlassCard(title: "Rol van deze Mac", icon: "laptopcomputer.and.arrow.down", glow: Theme.violet) {
                    Picker("", selection: $settings.clusterRole) {
                        Text("Hoofd-Mac: draait de modellen").tag("main")
                        Text("Helper: leent zijn GPU en geheugen uit").tag("helper")
                    }
                    .pickerStyle(.radioGroup)
                    Text(settings.clusterRole == "main"
                         ? "Op deze Mac chat je. Helpers die je aanvinkt, nemen een deel van het model op hun GPU."
                         : "Deze Mac rekent mee voor een hoofd-Mac. Laat hem aan staan en aangesloten zolang het model draait.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                if settings.clusterRole == "main" { MainSide() } else { HelperSide() }

                GlassCard(title: "Zo sluit je de Macs aan", icon: "cable.connector", glow: Theme.cyan) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Verbind elke helper met een Thunderbolt-kabel met de hoofd-Mac (Thunderbolt 4 of 5, geen gewone USB-C-kabel).")
                        Text("2. Op elke Mac: Systeeminstellingen → Netwerk → Thunderbolt-brug moet 'Verbonden' tonen (macOS kent zelf adressen toe).")
                        Text("3. Installeer MacDeepSeek op de helpers, kies daar 'Helper' en druk op Start helper.")
                        Text("4. Op de hoofd-Mac verschijnen de helpers hier vanzelf. Vink ze aan en start het model onder Modellen.")
                    }
                    .font(.callout)
                    Text("Met Thunderbolt 5 aan beide kanten gebruikt de verbinding RDMA (sneller); anders gewone TCP over de kabel. Per woord gaat er maar enkele tientallen KB over de kabel, dus ook Thunderbolt 4 is ruim genoeg.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
    }
}

private struct MainSide: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cluster: ClusterController
    @State private var manual = ""

    var body: some View {
        GlassCard(title: "Helpers", icon: "desktopcomputer", glow: Theme.mint) {
            if cluster.helpers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Zoeken naar helpers op het netwerk…").foregroundStyle(.secondary)
                }
            }
            ForEach(cluster.helpers) { h in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { cluster.selected.contains(h.id) },
                                             set: { if $0 { cluster.selected.insert(h.id) } else { cluster.selected.remove(h.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    Image(systemName: "desktopcomputer").foregroundStyle(Theme.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.name).font(.headline)
                        Text(h.manual ? "\(h.host):\(h.port) · handmatig toegevoegd"
                                      : "\(h.chip) · \(Int(h.memoryGB)) GB · GPU \(Int(h.gpuGB)) GB · \(h.host)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Badge(text: h.viaThunderbolt ? "Thunderbolt" : "Netwerk", icon: h.viaThunderbolt ? "bolt.horizontal.fill" : "wifi",
                          color: h.viaThunderbolt ? Theme.mint : Theme.amber)
                    if h.manual {
                        Button { cluster.remove(h) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                TextField("Helper handmatig toevoegen (adres:poort)", text: $manual).textFieldStyle(.roundedBorder)
                Button("Voeg toe") { cluster.addManual(manual); manual = "" }.disabled(manual.isEmpty)
            }
        }

        GlassCard(title: "Samen", icon: "memorychip", glow: Theme.violet) {
            let local = Double(app.system.effectiveGPULimit) / 1e9
            let extra = Double(cluster.extraGPU) / 1e9
            HStack(spacing: 24) {
                stat("Deze Mac", String(format: "%.0f GB", local))
                stat("Helpers", String(format: "+%.0f GB", extra))
                stat("Totaal voor de GPU's", String(format: "%.0f GB", local + extra))
            }
            if let plan = app.plan {
                Text(plan.fitsInMemory
                     ? "\(app.selectedModel?.name ?? "Het model") past zo helemaal in het geheugen van het cluster."
                     : "\(app.selectedModel?.name ?? "Het model") past nog niet helemaal: de meest gebruikte experts (\(plan.expertCache.gbShort)) staan in de GPU-cache van deze Mac, de rest (\(plan.streamedExperts.gbShort)) komt van de SSD.")
                    .font(.callout).foregroundStyle(plan.fitsInMemory ? Theme.mint : Theme.amber)
                if !plan.tensorSplit.isEmpty {
                    Text("Lagen: " + zip(cluster.active.map(\.name), plan.tensorSplit).map { "\($0) \($1)" }.joined(separator: " · ") + " · deze Mac \(max(plan.tensorSplit.last ?? 1, 1) - 1)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Wijzigingen gelden bij de volgende start van de engine.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title2, design: .rounded).weight(.bold)).foregroundStyle(Theme.cool)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct HelperSide: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cluster: ClusterController
    @EnvironmentObject var settings: Settings

    var body: some View {
        GlassCard(title: "Helper", icon: "cpu", glow: Theme.mint) {
            HStack {
                Circle().fill(cluster.helperRunning ? Theme.mint : .gray).frame(width: 9, height: 9)
                Text(cluster.helperRunning ? "Helper actief op \(cluster.helperAddress)" : "Helper uit")
                    .font(.headline)
                Spacer()
                if cluster.helperRunning {
                    Button("Stop helper", role: .destructive) { cluster.stopHelper() }
                } else {
                    Button { cluster.startHelper() } label: { Label("Start helper", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.mint)
                }
            }
            // a helper's GPU may hold about 75% of its memory by default; raised, it takes more layers of the model
            let suggested = Int((app.system.physicalMemory - MemoryPlanner.osHeadroom) >> 20)
            if app.system.wiredLimitMB < suggested - 1024 {
                HStack {
                    Text("De GPU van deze Mac mag nu \(app.system.effectiveGPULimit.gb) gebruiken.").font(.callout)
                    Spacer()
                    Button("Verhoog naar \((UInt64(suggested) << 20).gb)") {
                        app.raiseWiredLimit(mb: suggested)
                        // the helper announces its GPU memory when it starts
                        if cluster.helperRunning { cluster.restartHelper() }
                    }
                    .help("Voert 'sysctl iogpu.wired_limit_mb' uit (vraagt je wachtwoord). Geldt tot de volgende herstart.")
                }
            }
            Toggle("Ook bereikbaar via het lokale netwerk (niet alleen via Thunderbolt)", isOn: $settings.clusterAllowLAN)
            Text("Let op: de helper heeft geen wachtwoord. Gebruik hem alleen op een directe kabel of een vertrouwd netwerk.")
                .font(.caption).foregroundStyle(Theme.amber)
            Text("Adressen van deze Mac: " + ClusterController.addresses().map { "\($0.interface) \($0.ip)" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !cluster.helperLog.isEmpty {
                ScrollView {
                    Text(cluster.helperLog.suffix(60).joined(separator: "\n")).font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 140)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
