import SwiftUI
import Charts

/// Measures every downloaded model the same way and puts them side by side.
struct CompareView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var bench: BenchmarkRunner
    @EnvironmentObject var models: ModelStore
    @State private var selection: Set<String> = []

    private var ready: [ModelInfo] { models.catalog.all.filter { models.status($0.id).isComplete } }
    private var text: [BenchResult] { bench.latest.filter { !$0.makesImage } }
    private var images: [BenchResult] { bench.latest.filter(\.makesImage) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Vergelijken")).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(L("Dezelfde meting op elk model: een prompt van ~2.500 tokens lezen en 300 tokens schrijven, of een afbeelding van 1024 × 1024 maken."))
                            .foregroundStyle(.secondary)
                    }
                }

                GlassCard(title: L("Meten"), icon: "stopwatch.fill", glow: Theme.violet) {
                    if ready.isEmpty {
                        Text(L("Nog geen model gedownload.")).foregroundStyle(.secondary)
                    }
                    ForEach(ready) { m in
                        Toggle(isOn: Binding(get: { selection.contains(m.id) },
                                             set: { if $0 { selection.insert(m.id) } else { selection.remove(m.id) } })) {
                            HStack {
                                Circle().fill(Theme.familyGradient(m.family)).frame(width: 10, height: 10)
                                Text(m.name)
                                Text(L(key: m.summary)).font(.caption).foregroundStyle(.secondary)
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
                                let ids = models.catalog.all.map(\.id).filter(selection.contains)
                                Task { await bench.run(ids, app: app) }
                            } label: { Label(L("Start meting"), systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent).tint(Theme.violet).disabled(selection.isEmpty)
                            if !bench.results.isEmpty {
                                Button(L("Wis resultaten"), role: .destructive) { bench.clear() }
                            }
                        }
                    }
                    Text(L("Elk model wordt om de beurt gestart; grote modellen laden de eerste keer enkele minuten."))
                        .font(.caption).foregroundStyle(.tertiary)
                }

                if !bench.latest.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                        if !text.isEmpty {
                            BarCard(title: L("Schrijven"), unit: "tokens/s", icon: "bolt.fill", results: text, value: \.decodeTPS)
                            BarCard(title: L("Prompt lezen"), unit: "tokens/s", icon: "text.viewfinder", results: text, value: \.promptTPS)
                            BarCard(title: L("Laadtijd"), unit: "seconden", icon: "hourglass", results: text, value: \.loadSeconds)
                            BarCard(title: L("SSD tijdens schrijven"), unit: "MB/s", icon: "internaldrive", results: text, value: \.ssdMBs)
                        }
                        if !images.isEmpty {
                            BarCard(title: L("Afbeelding van 1024 × 1024, met laden"), unit: "seconden", icon: "photo", results: images, value: \.imageSecondsOrZero)
                            BarCard(title: L("Beeldtokens"), unit: "tokens/s", icon: "bolt.fill", results: images, value: \.decodeTPS)
                        }
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
        return r.cpuMoELayers == 0 ? "GPU" : L("\(r.cpuMoELayers) lagen CPU")
    }

    var body: some View {
        GlassCard(title: L("Alle cijfers"), icon: "tablecells", glow: Theme.cyan) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach([L("Model"), L("Schrijven"), L("Lezen"), L("Laden"), "SSD", L("GPU-geheugen"), L("Experts"), L("Afbeelding"), L("Gemeten")], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(results) { r in
                    GridRow {
                        Text(r.modelName).fontWeight(.medium)
                        Text(String(format: "%.1f tok/s", r.decodeTPS))
                        Text(r.makesImage ? "–" : String(format: "%.0f tok/s", r.promptTPS))
                        Text(r.makesImage ? "–" : String(format: "%.0f s", r.loadSeconds))
                        Text(String(format: "%.0f MB/s", r.ssdMBs))
                        Text(String(format: "%.0f GB", r.wiredGB))
                        Text(r.makesImage ? "–" : experts(r))
                        Text(r.imageSeconds.map { String(format: "%.0f s", $0) } ?? "–")
                        Text(r.date, style: .date).foregroundStyle(.secondary)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
    }
}
