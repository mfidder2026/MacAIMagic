import SwiftUI

/// The system check: what MacAIMagic needs on this Mac, what it put right itself, and what it offers to install.
struct SystemView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var check: SystemCheck
    var open: (Pane) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Systeem")).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(summary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if check.running { ProgressView().controlSize(.small) }
                    Button(L("Opnieuw controleren")) { Task { await check.run(app: app) } }.disabled(check.running)
                }
                GlassCard(glow: check.needsAttention ? Theme.amber : Theme.mint) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(check.items.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().opacity(0.4) }
                            row(item)
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var summary: String {
        if check.running && check.items.isEmpty { return L("Bezig met controleren…") }
        if check.needsAttention { return L("Er is iets dat de app tegenhoudt; zie hieronder.") }
        if check.items.contains(where: { $0.state == .todo }) { return L("Alles is in orde; alleen een model ontbreekt nog.") }
        return L("Alles wat MacAIMagic nodig heeft is aanwezig.")
    }

    private func row(_ item: SystemCheck.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(item.state)).foregroundStyle(color(item.state)).font(.system(size: 17)).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let a = item.action {
                Button(a.label) { check.perform(a.action, app: app, open: open) }
                    .buttonStyle(.borderedProminent).tint(color(item.state))
            }
        }
        .padding(.vertical, 10)
    }

    private func icon(_ s: SystemCheck.State) -> String {
        switch s {
        case .ok: "checkmark.circle.fill"
        case .fixed: "wrench.and.screwdriver.fill"
        case .todo: "arrow.down.circle.fill"
        case .optional: "plus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func color(_ s: SystemCheck.State) -> Color {
        switch s {
        case .ok, .fixed: Theme.mint
        case .todo: Theme.accent
        case .optional: Theme.cyan
        case .failed: Theme.amber
        }
    }
}
