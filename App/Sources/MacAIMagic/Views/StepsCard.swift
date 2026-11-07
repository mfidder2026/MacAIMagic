import SwiftUI

/// The model's step list for this conversation, above the composer: what it does now and what is done.
struct StepsCard: View {
    let steps: [WorkStep]
    let busy: Bool
    @State private var open = true

    var body: some View {
        let done = steps.filter(\.isDone).count
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist").foregroundStyle(Theme.cool)
                    Text(L("Stappen")).font(.callout.weight(.semibold))
                    Text("\(done)/\(steps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let now = steps.first(where: { $0.status == "doing" }), !open {
                        Text(now.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        switch step.status {
                        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                        case "doing":
                            if busy { ProgressView().controlSize(.mini).frame(width: 14) }
                            else { Image(systemName: "circle.dotted").foregroundStyle(Theme.amber) }
                        default: Image(systemName: "circle").foregroundStyle(.secondary)
                        }
                        Text(step.title).font(.callout)
                            .foregroundStyle(step.isDone ? .secondary : .primary)
                            .strikethrough(step.isDone, color: .secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20).padding(.bottom, 4)
        .frame(maxWidth: 820)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Stappen: \(done) van \(steps.count) klaar"))
    }
}
