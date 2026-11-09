import SwiftUI

/// A round gauge with the percentage while a model loads or unloads (amber loading, blue unloading). It runs on the
/// engine's clock (LoadClock), and on what the engine reports when that is further. Taken over from WinAIMagic.
struct LoadGauge: View {
    @ObservedObject var engine: EngineController
    var size: CGFloat = 13
    var showsText = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let f = engine.phaseFraction(at: context.date)
            let color = Theme.status(engine.state)
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(color.opacity(0.25), lineWidth: max(2, size / 7))
                    Circle().trim(from: 0, to: f).stroke(color, style: StrokeStyle(lineWidth: max(2, size / 7), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if size >= 30 { Text("\(Int(f * 100))%").font(.system(size: size / 3.6, weight: .semibold)).monospacedDigit() }
                }
                .frame(width: size, height: size)
                .animation(.linear(duration: 0.5), value: f)
                if showsText { Text("\(Int(f * 100))%").monospacedDigit() }
            }
        }
    }
}
