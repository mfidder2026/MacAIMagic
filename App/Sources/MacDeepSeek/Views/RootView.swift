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
        .safeAreaInset(edge: .bottom) { SidebarSpeed().padding(12) }
    }
}

/// A tiny live speed line at the bottom of the sidebar.
private struct SidebarSpeed: View {
    @EnvironmentObject var metrics: LiveMetrics

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill").foregroundStyle(Theme.violet)
            Text(String(format: "%.1f tok/s", metrics.current?.tokensPerSec ?? 0)).font(.caption.monospacedDigit())
            Spacer()
            Text(String(format: "GPU %.0f%%", metrics.current?.gpu ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
