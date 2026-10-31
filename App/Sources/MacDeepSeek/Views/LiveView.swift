import SwiftUI
import Charts

/// The live dashboard: a big speed gauge and real-time charts of what the Mac is doing.
struct LiveView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var metrics: LiveMetrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(alignment: .top, spacing: 18) {
                    GlassCard(glow: Theme.violet) {
                        VStack(spacing: 14) {
                            GaugeRing(value: metrics.current?.tokensPerSec ?? 0, maximum: 30, label: "SCHRIJFSNELHEID", unit: "tokens / s", size: 210)
                            HStack(spacing: 18) {
                                MiniStat(label: "GPU", value: metrics.current?.gpu ?? 0, unit: "%", color: Theme.accent)
                                MiniStat(label: "CPU", value: metrics.current?.cpu ?? 0, unit: "%", color: Theme.cyan)
                                MiniStat(label: "SSD", value: metrics.current?.ssdMBs ?? 0, unit: "MB/s", color: Theme.amber)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(width: 300)
                    VStack(spacing: 18) {
                        ChartCard(title: "Tokens per seconde", icon: "bolt.fill", color: Theme.violet,
                                  value: String(format: "%.1f tok/s", metrics.current?.tokensPerSec ?? 0)) {
                            AreaSeries(samples: metrics.samples, value: \.tokensPerSec, color: Theme.violet, maxY: 30)
                        }
                        ChartCard(title: "GPU en CPU", icon: "cpu", color: Theme.accent,
                                  value: String(format: "GPU %.0f%% · CPU %.0f%%", metrics.current?.gpu ?? 0, metrics.current?.cpu ?? 0)) {
                            DualLine(samples: metrics.samples)
                        }
                    }
                }
                HStack(spacing: 18) {
                    ChartCard(title: "Geheugen", icon: "memorychip", color: Theme.pink,
                              value: String(format: "%.0f / %.0f GB", metrics.current?.usedGB ?? 0, metrics.totalMemoryGB)) {
                        MemoryChart(samples: metrics.samples, total: metrics.totalMemoryGB)
                    }
                    ChartCard(title: "SSD lezen", icon: "internaldrive", color: Theme.amber,
                              value: String(format: "%.0f MB/s", metrics.current?.ssdMBs ?? 0)) {
                        AreaSeries(samples: metrics.samples, value: \.ssdMBs, color: Theme.amber, maxY: nil)
                    }
                }
                if let plan = app.plan { PlanStrip(plan: plan) }
            }
            .padding(28)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandMark(size: 44, active: (metrics.current?.tokensPerSec ?? 0) > 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("Live").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(engine.model?.name ?? app.selectedModel?.name ?? "Geen model")
                    .font(.system(.title3, design: .rounded)).foregroundStyle(.secondary)
            }
            Spacer()
            EngineStatusPill()
            EngineButton()
        }
    }
}

struct MiniStat: View {
    let label: String
    let value: Double
    let unit: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(color)
                .contentTransition(.numericText(value: value)).animation(.snappy, value: value)
            Text("\(label) \(unit)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    let value: String
    @ViewBuilder var chart: Content

    var body: some View {
        GlassCard(glow: color) {
            HStack {
                Label(title, systemImage: icon).font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                Text(value).font(.system(.callout, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
            }
            chart.chartPlotStyle { $0.clipped() }.frame(height: 130)
        }
    }
}

/// One series as a glowing line over a gradient area.
struct AreaSeries: View {
    let samples: [LiveMetrics.Sample]
    let value: KeyPath<LiveMetrics.Sample, Double>
    let color: Color
    let maxY: Double?

    var body: some View {
        Chart(samples) { s in
            AreaMark(x: .value("t", s.t), y: .value("v", s[keyPath: value]))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", s.t), y: .value("v", s[keyPath: value]))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2.2))
                .shadow(color: color, radius: 4)
        }
        .chartYScale(domain: 0...(maxY ?? max(10, (samples.map { $0[keyPath: value] }.max() ?? 10) * 1.2)))
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.06)); AxisValueLabel() } }
    }
}

struct DualLine: View {
    let samples: [LiveMetrics.Sample]

    var body: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("t", s.t), y: .value("%", s.gpu), series: .value("s", "GPU"), stacking: .unstacked)
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", s.t), y: .value("%", s.gpu), series: .value("s", "GPU"))
                    .interpolationMethod(.catmullRom).foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 2.2))
                LineMark(x: .value("t", s.t), y: .value("%", s.cpu), series: .value("s", "CPU"))
                    .interpolationMethod(.catmullRom).foregroundStyle(Theme.cyan).lineStyle(StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
            }
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.06)); AxisValueLabel() } }
    }
}

struct MemoryChart: View {
    let samples: [LiveMetrics.Sample]
    let total: Double

    var body: some View {
        Chart {
            ForEach(samples) { s in
                // two overlapping areas, not a stack: wired memory is part of the used memory
                AreaMark(x: .value("t", s.t), y: .value("GB", s.usedGB), series: .value("s", "gebruikt"), stacking: .unstacked)
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Theme.pink.opacity(0.35), Theme.pink.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                AreaMark(x: .value("t", s.t), y: .value("GB", s.wiredGB), series: .value("s", "GPU"), stacking: .unstacked)
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Theme.violet.opacity(0.6), Theme.violet.opacity(0.1)], startPoint: .top, endPoint: .bottom))
            }
            RuleMark(y: .value("totaal", total))
                .foregroundStyle(.white.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .annotation(position: .bottom, alignment: .leading) { Text("\(Int(total)) GB").font(.caption2).foregroundStyle(.secondary) }
        }
        .chartYScale(domain: 0...(total * 1.08))
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine().foregroundStyle(.white.opacity(0.06)); AxisValueLabel() } }
    }
}

/// The memory plan as one glowing bar: dense, GPU experts, CPU experts, streamed, free.
struct PlanStrip: View {
    let plan: MemoryPlan

    var body: some View {
        GlassCard(title: "Waar het model staat", icon: "square.stack.3d.up.fill", glow: Theme.cyan) {
            let total = Double(plan.physical)
            let parts: [(String, Double, Color)] = [
                ("Vast (GPU)", Double(plan.dense + plan.overhead), Theme.violet),
                ("Experts GPU", Double(plan.gpuExperts), Theme.accent),
                ("Experts CPU", Double(plan.cpuExperts - min(plan.cpuExperts, plan.streamedExperts)), Theme.cyan),
            ]
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        RoundedRectangle(cornerRadius: 4).fill(p.2.gradient)
                            .frame(width: max(0, geo.size.width * min(p.1 / total, 1)))
                            .shadow(color: p.2.opacity(0.7), radius: 6)
                    }
                    RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.06))
                }
            }
            .frame(height: 18)
            HStack(spacing: 16) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.2).frame(width: 8, height: 8)
                        Text("\(p.0) \(UInt64(p.1).gbShort)")
                    }
                }
                if plan.streamedExperts > 0 {
                    HStack(spacing: 5) { Circle().fill(Theme.amber).frame(width: 8, height: 8); Text("Van SSD \(plan.streamedExperts.gbShort)") }
                }
                if plan.engram > 0 {
                    HStack(spacing: 5) { Circle().fill(Theme.amber.opacity(0.5)).frame(width: 8, height: 8); Text("Engram (SSD) \(plan.engram.gbShort)") }
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Start / stop for the selected model, used in several places.
struct EngineButton: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: EngineController

    var body: some View {
        switch engine.state {
        case .running, .starting:
            Button(role: .destructive) { engine.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.bordered)
        default:
            Button { app.startEngine() } label: { Label("Start", systemImage: "play.fill").padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!app.canStart)
        }
    }
}
