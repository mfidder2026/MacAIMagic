import SwiftUI

enum Pane: Hashable { case engine, chat(Conversation.ID) }

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: ConversationStore
    @EnvironmentObject var engine: EngineController
    @EnvironmentObject var models: ModelStore
    @State private var pane: Pane?

    var body: some View {
        NavigationSplitView {
            Sidebar(pane: $pane)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            switch pane {
            case .engine?:
                EngineView()
            case .chat(let id)?:
                ChatView(conversationID: id).id(id)
            case nil:
                EngineView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                EngineStatusPill().onTapGesture { pane = .engine }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.newConversation()
                    if let id = store.selection { pane = .chat(id) }
                } label: { Label("Nieuw gesprek", systemImage: "square.and.pencil") }
            }
        }
        .onAppear {
            // first run: show the setup until the model is there
            pane = models.isComplete ? store.selection.map { .chat($0) } : .engine
        }
        .onChange(of: pane) { _, new in
            if case .chat(let id) = new { store.selection = id }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: ConversationStore
    @Binding var pane: Pane?

    var body: some View {
        List(selection: $pane) {
            Section {
                Label("Engine & model", systemImage: "cpu").tag(Pane.engine)
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
    }
}

struct EngineStatusPill: View {
    @EnvironmentObject var engine: EngineController

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .help("Engine-status: klik voor details")
    }

    private var color: Color {
        switch engine.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }
    private var label: String {
        switch engine.state {
        case .running: return "DeepSeek-V4.1 actief"
        case .starting(let s): return s
        case .failed: return "Engine fout"
        case .stopped: return "Engine uit"
        }
    }
}
