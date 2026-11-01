import SwiftUI
import Charts

/// Measures every downloaded model the same way and puts them side by side.
struct CompareView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var bench: BenchmarkRunner
    @EnvironmentObject var models: ModelStore
    @State private var selection: Set<String> = []

    private var ready: [ModelInfo] { models.catalog.models.filter { models.status($0.id).isComplete } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vergelijken").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Dezelfde meting op elk model: een prompt van ~2.500 tokens lezen en 300 tokens schrijven.")
                            .foregroundStyle(.secondary)
                    }
                }

                GlassCard(title: "Meten", icon: "stopwatch.fill", glow: Theme.violet) {
                    if ready.isEmpty {
                        Text("Nog geen model gedownload.").foregroundStyle(.secondary)
                    }
                    ForEach(ready) { m in
                        Toggle(isOn: Binding(get: { selection.contains(m.id) },
                                             set: { if $0 { selection.insert(m.id) } else { selection.remove(m.id) } })) {
                            HStack {
                                Circle().fill(Theme.familyGradient(m.family)).frame(width: 10, height: 10)
                                Text(m.name)
                                Text(m.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    HStack {
                        if let running = bench.running {
                            ProgressView().controlSize(.small)
                            Text("\(running): \(bench.step)").foregroundStyle(.secondary)
                        } else {
                            Button {
                                let ids = models.catalog.models.map(\.id).filter(selection.contains)
                                Task { await bench.run(ids, app: app) }
                            } label: { Label("Start meting", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).tint(Theme.violet).disabled(selection.isEmpty)
                            if !bench.results.isEmpty {
                                Button("Wis resultaten", role: .destructive) { bench.clear() }
                            }
                        }
                    }
                    Text("Elk model wordt om de beurt gestart; grote modellen laden de eerste keer enkele minuten.")
                        .font(.caption).foregroundStyle(.tertiary)
                }

                if !bench.latest.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                        BarCard(title: "Schrijven", unit: "tokens/s", icon: "bolt.fill", results: bench.latest, value: \.decodeTPS)
                        BarCard(title: "Prompt lezen", unit: "tokens/s", icon: "text.viewfinder", results: bench.latest, value: \.promptTPS)
                        BarCard(title: "Laadtijd", unit: "seconden", icon: "hourglass", results: bench.latest, value: \.loadSeconds)
                        BarCard(title: "SSD tijdens schrijven", unit: "MB/s", icon: "internaldrive", results: bench.latest, value: \.ssdMBs)
                    }
                    ResultsTable(results: bench.latest)
                }
            }
            .padding(28)
        }
        .onAppear { if selection.isEmpty { selection = Set(ready.map(\.id)) } }
    }
}

private struct BarCard: View {
    let title: String
    let unit: String
    let icon: String
    let results: [BenchResult]
    let value: KeyPath<BenchResult, Double>

    var body: some View {
        GlassCard(title: title, icon: icon, glow: Theme.accent) {
            Chart(results) { r in
                let family = ModelCatalog.shared.model(r.modelID)?.family ?? "deepseek"
                BarMark(x: .value(unit, r[keyPath: value]), y: .value("Model", r.modelName))
                    .foregroundStyle(Theme.familyGradient(family))
                    .cornerRadius(6)
                    .annotation(position: .trailing) {
                        Text(r[keyPath: value], format: .number.precision(.fractionLength(1)))
                            .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                    }
            }
            .chartXAxisLabel(unit)
            .frame(height: CGFloat(max(results.count, 1)) * 44 + 30)
        }
    }
}

private struct ResultsTable: View {
    let results: [BenchResult]

    /// Where the experts were: all on the GPU, some layers on the CPU, or mapped from the SSD with a GPU cache.
    private func experts(_ r: BenchResult) -> String {
        if let cache = r.expertCacheGB, cache > 0 { return String(format: "cache %.0f GB", cache) }
        return r.cpuMoELayers == 0 ? "GPU" : "\(r.cpuMoELayers) lagen CPU"
    }

    var body: some View {
        GlassCard(title: "Alle cijfers", icon: "tablecells", glow: Theme.cyan) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(["Model", "Schrijven", "Lezen", "Laden", "SSD", "GPU-geheugen", "Experts", "Gemeten"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(results) { r in
                    GridRow {
                        Text(r.modelName).fontWeight(.medium)
                        Text(String(format: "%.1f tok/s", r.decodeTPS))
                        Text(String(format: "%.0f tok/s", r.promptTPS))
                        Text(String(format: "%.0f s", r.loadSeconds))
                        Text(String(format: "%.0f MB/s", r.ssdMBs))
                        Text(String(format: "%.0f GB", r.wiredGB))
                        Text(experts(r))
                        Text(r.date, style: .date).foregroundStyle(.secondary)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }
}
