import SwiftUI

enum Pane: Hashable { case live, models, compare, chat(Conversation.ID) }

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var metrics: LiveMetrics
    @State private var pane: Pane?

    var body: some View {
        NavigationSplitView {
            Sidebar(pane: $pane)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            ZStack {
                AuroraBackground(energy: min((metrics.current?.tokensPerSec ?? 0) / 20, 1))
                Group {
                    switch pane {
                    case .live?: LiveView()
                    case .models?, nil: ModelsView()
                    case .compare?: CompareView()
                    case .chat(let id)?: ChatView(conversationID: id).id(id)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            .animation(.easeInOut(duration: 0.25), value: pane)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EngineStatusPill().onTapGesture { pane = .live }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.newConversation()
                    if let id = store.selection { pane = .chat(id) }
                } label: { Label("Nieuw gesprek", systemImage: "square.and.pencil") }
            }
        }
        .onAppear {
            // first run: show the models until one is there
            let ready = models.status(app.selectedModelID).isComplete
            pane = ready ? store.selection.map { .chat($0) } : .models
        }
        .onChange(of: pane) { _, new in
            if case .chat(let id) = new { store.selection = id }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var metrics: LiveMetrics
    @Binding var pane: Pane?

    var body: some View {
        List(selection: $pane) {
            Section {
                HStack(spacing: 10) {
                    BrandMark(size: 30, active: (metrics.current?.tokensPerSec ?? 0) > 0)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("MacDeepSeek").font(.system(.headline, design: .rounded).weight(.bold))
                        Text(app.selectedModel?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 6)
                .selectionDisabled()
            }
            Section {
                Label("Live", systemImage: "waveform.path.ecg").tag(Pane.live)
                Label("Modellen", systemImage: "square.stack.3d.up").tag(Pane.models)
                Label("Vergelijken", systemImage: "chart.bar.xaxis").tag(Pane.compare)
            }
            Section("Gesprekken") {
                ForEach(store.conversations) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).lineLimit(1)
                        Text(c.updated, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(Pane.chat(c.id))
                    .contextMenu {
                        Button("Verwijderen", role: .destructive) { store.delete(c.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            MiniDashboard { pane = .live }.padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
}

/// The live dashboard in miniature, at the bottom of the sidebar: speed gauge and sparklines of every metric.
struct MiniDashboard: View {
    var open: () -> Void
    @EnvironmentObject var metrics: LiveMetrics
    @EnvironmentObject var engine: EngineController
    @State private var hover = false

    var body: some View {
        let now = metrics.current
        let recent = Array(metrics.samples.suffix(80))
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    GaugeRing(value: now?.tokensPerSec ?? 0, maximum: 60, label: "", unit: "tok/s", size: 50)
                    MiniSpark(values: recent.map(\.tokensPerSec), color: Theme.violet, maxY: nil)
                        .frame(height: 34)
                }
                VStack(spacing: 5) {
                    MiniRow(label: "GPU", value: String(format: "%.0f%%", now?.gpu ?? 0), color: Theme.accent,
                            values: recent.map(\.gpu), maxY: 100)
                    MiniRow(label: "CPU", value: String(format: "%.0f%%", now?.cpu ?? 0), color: Theme.cyan,
                            values: recent.map(\.cpu), maxY: 100)
                    MiniRow(label: "RAM", value: String(format: "%.0f GB", now?.usedGB ?? 0), color: Theme.pink,
                            values: recent.map(\.usedGB), maxY: metrics.totalMemoryGB)
                    MiniRow(label: "SSD", value: ssd(now?.ssdMBs ?? 0), color: Theme.amber,
                            values: recent.map(\.ssdMBs), maxY: nil)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(
                LinearGradient(colors: [Theme.violet.opacity(hover ? 0.8 : 0.45), .white.opacity(0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: Theme.violet.opacity(engine.state.isRunning ? 0.25 : 0), radius: 10)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Klik voor het volledige live dashboard")
    }

    private func ssd(_ mbs: Double) -> String {
        mbs >= 1000 ? String(format: "%.1f GB/s", mbs / 1000) : String(format: "%.0f MB/s", mbs)
    }
}

/// One metric as a row: label, sparkline, current value.
private struct MiniRow: View {
    let label: String
    let value: String
    let color: Color
    let values: [Double]
    let maxY: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(color.opacity(0.9))
                .frame(width: 24, alignment: .leading)
            MiniSpark(values: values, color: color, maxY: maxY).frame(height: 16)
            Text(value).font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.85)).lineLimit(1).fixedSize()
        }
    }
}

/// A tiny area chart: gradient fill under a glowing line, scaled to maxY (or to the largest value).
struct MiniSpark: View {
    let values: [Double]
    let color: Color
    let maxY: Double?

    var body: some View {
        GeometryReader { geo in
            let top = max(maxY ?? (values.max() ?? 1) * 1.15, 0.001)
            let step = geo.size.width / CGFloat(max(values.count - 1, 1))
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            ZStack {
                Path { p in
                    guard let first = pts.first, let last = pts.last else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                }
                .fill(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .shadow(color: color.opacity(0.8), radius: 2)
            }
        }
    }
}

struct EngineStatusPill: View {
    @EnvironmentObject var engine: EngineController
    @State private var blink = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color, radius: blink ? 6 : 2)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { blink = true } }
            Text(label).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
        .help("Engine-status: klik voor het live dashboard")
    }

    private var color: Color {
        switch engine.state {
        case .running: return Theme.mint
        case .starting: return Theme.amber
        case .failed: return .red
        case .stopped: return .gray
        }
    }
    private var label: String {
        switch engine.state {
        case .running: return "\(engine.model?.shortName ?? "Model") actief"
        case .starting(let s): return s
        case .failed: return "Engine fout"
        case .stopped: return "Engine uit"
        }
    }
}
