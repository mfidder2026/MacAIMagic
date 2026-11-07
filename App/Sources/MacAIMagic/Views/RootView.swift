import SwiftUI

enum Pane: Hashable { case live, models, documents, images, compare, cluster, system, tasks, help, chat(Conversation.ID) }

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
                    case .documents?: DocumentsView()
                    case .images?: ImagesView()
                    case .compare?: CompareView()
                    case .cluster?: ClusterView()
                    case .system?: SystemView { pane = $0 }
                    case .tasks?: TasksView { pane = $0 }
                    case .help?: HelpView()
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
                // the help for the page on screen
                Button { HelpCenter.shared.open(HelpCenter.topic(for: pane)) } label: { Label(L("Hulp"), systemImage: "questionmark.circle") }
                    .help(L("Hulp bij dit onderdeel"))
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Label(L("Instellingen"), systemImage: "gearshape") }
                    .help(L("Instellingen (⌘,)"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.newConversation()
                    if let id = store.selection { pane = .chat(id) }
                } label: { Label(L("Nieuw gesprek"), systemImage: "square.and.pencil") }
            }
        }
        .onAppear {
            // first run: show the models until one is there
            let ready = models.status(app.selectedModelID).isComplete
            pane = ready ? store.selection.map { .chat($0) } : .models
        }
        .task {
            // what this Mac needs is checked at every start; the very first start, or something in the way, shows it
            await app.check.run(app: app)
            if app.check.needsAttention || !Settings.shared.systemCheckSeen { pane = .system }
            Settings.shared.systemCheckSeen = true
        }
        .onReceive(HelpCenter.shared.$openRequest.dropFirst()) { _ in pane = .help }
        .onReceive(AppNavigator.shared.$pane.compactMap { $0 }) { p in pane = p; AppNavigator.shared.pane = nil }
        // a click on a notification: its conversation
        .onReceive(Notifier.shared.$openRequest.compactMap { $0 }) { id in
            guard store.conversations.contains(where: { $0.id == id }) else { return }
            store.selection = id
            pane = .chat(id)
        }
        .onChange(of: pane) { _, new in
            if case .chat(let id) = new { store.selection = id }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var chat: ChatClient
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var metrics: LiveMetrics
    @Binding var pane: Pane?

    /// Room for the window's close, minimize and zoom buttons. The sidebar reaches the top of the window, and macOS does
    /// not always keep a list clear of them, so the name stands outside the list at a fixed place.
    static let windowButtonsHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 30, active: (metrics.current?.tokensPerSec ?? 0) > 0)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(L("MacAIMagic")).font(.system(.headline, design: .rounded).weight(.bold)).lineLimit(1).fixedSize()
                        if let version = Paths.appVersion { Text("v" + version).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Text(app.selectedModel?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.top, Self.windowButtonsHeight)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            list
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var list: some View {
        List(selection: $pane) {
            Section {
                Label(L("Live"), systemImage: "waveform.path.ecg").tag(Pane.live)
                Label(L("Modellen"), systemImage: "square.stack.3d.up").tag(Pane.models)
                Label(L("Documenten"), systemImage: "doc.richtext").tag(Pane.documents)
                Label(L("Beeld"), systemImage: "photo").tag(Pane.images)
                Label(L("Taken"), systemImage: "clock.badge.checkmark").tag(Pane.tasks)
                Label(L("Cluster"), systemImage: "point.3.connected.trianglepath.dotted").tag(Pane.cluster)
                Label(L("Vergelijken"), systemImage: "chart.bar.xaxis").tag(Pane.compare)
                Label(L("Systeem"), systemImage: "checkmark.shield").tag(Pane.system)
                Label(L("Hulp"), systemImage: "questionmark.circle").tag(Pane.help)
            }
            Section(L("Gesprekken")) {
                ForEach(store.conversations.filter { $0.hidden != true }) { c in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayTitle).lineLimit(1)
                            Text(c.updated, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        // at work, or waiting for the user's approval
                        if chat.approvals[c.id] != nil {
                            Circle().fill(Theme.amber).frame(width: 7, height: 7).help(L("Wacht op jouw goedkeuring"))
                        } else if chat.isBusy(c.id) {
                            ProgressView().controlSize(.mini).help(L("Bezig"))
                        }
                    }
                    .tag(Pane.chat(c.id))
                    .contextMenu {
                        if chat.isBusy(c.id) { Button(L("Stoppen")) { chat.stop(c.id) } }
                        Button(L("Verwijderen"), role: .destructive) { store.delete(c.id) }.disabled(chat.isBusy(c.id))
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
                    GaugeRing(value: now?.tokensPerSec ?? 0, maximum: metrics.scale(base: 60), label: "", unit: "tok/s", size: 50)
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
        .help(L("Klik voor het volledige live dashboard"))
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
    @EnvironmentObject var app: AppState
    /// False: only the app's own engine, beside its Start and Stop.
    var all = true

    var body: some View {
        PillBody(engine: app.engine, fast: app.documentEngines.fast, images: app.images, all: all)
    }
}

/// Every model that is in memory, with what it does: the chat engine (Zwaar), the second engine (Snel) and the image model
/// while it draws. Green: runs; amber: loading; red: failed; grey: nothing in memory.
private struct PillBody: View {
    @ObservedObject var engine: EngineController
    @ObservedObject var fast: EngineController
    @ObservedObject var images: ImageMaker
    let all: Bool
    @EnvironmentObject var app: AppState

    private struct Part { let text: String; let color: Color; let rank: Int }

    private func part(_ e: EngineController, role: String) -> Part? {
        let name = e.model?.shortName ?? L("Model")
        switch e.state {
        case .running: return Part(text: L("\(name) actief (\(role))"), color: Theme.mint, rank: 1)
        case .starting: return Part(text: L("\(name) laden… (\(role))"), color: Theme.amber, rank: 2)
        case .failed: return Part(text: L("\(name): fout"), color: .red, rank: 3)
        case .stopped: return nil
        }
    }

    private var parts: [Part] {
        var list = [part(engine, role: L("Zwaar"))].compactMap { $0 }
        guard all else { return list }
        if let p = part(fast, role: L("Snel")) { list.append(p) }
        if images.busy { list.append(Part(text: L("\(app.imageModel?.shortName ?? L("Beeld")) tekent"), color: Theme.mint, rank: 1)) }
        return list
    }

    var body: some View {
        let list = parts
        let color = list.max { $0.rank < $1.rank }?.color ?? .gray
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8).shadow(color: color, radius: 4)
            Text(list.isEmpty ? L("Geen model geladen") : list.map(\.text).joined(separator: " · "))
                .font(.callout.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
        .help(L("Welke modellen in het geheugen staan: klik voor het live dashboard"))
    }
}
