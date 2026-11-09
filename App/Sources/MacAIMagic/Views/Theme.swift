import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.48, blue: 1.0)          // electric blue
    static let violet = Color(red: 0.62, green: 0.36, blue: 1.0)
    static let cyan = Color(red: 0.20, green: 0.86, blue: 0.95)
    static let pink = Color(red: 1.0, green: 0.36, blue: 0.68)
    static let mint = Color(red: 0.30, green: 0.95, blue: 0.62)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let night = Color(red: 0.035, green: 0.04, blue: 0.09)

    static let brand = LinearGradient(colors: [accent, violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cool = LinearGradient(colors: [cyan, accent], startPoint: .leading, endPoint: .trailing)
    static let userBubble = LinearGradient(colors: [accent.opacity(0.55), violet.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The colour of an engine's state, in the status pill and on the model chip: green runs, amber loads, pink failed,
    /// blue unloads, grey off. (A family colour on the chip read as "not loaded".)
    static func status(_ s: EngineController.State) -> Color {
        switch s {
        case .running: return mint
        case .starting: return amber
        case .failed: return pink
        case .stopping: return Color(red: 0.4, green: 0.6, blue: 1.0)
        case .stopped: return Color(white: 0.55)
        }
    }

    /// What that state means, as a tooltip.
    static func statusText(_ s: EngineController.State) -> String {
        switch s {
        case .running: return L("Model geladen")
        case .starting(let message): return message
        case .failed: return L("Engine fout")
        case .stopping: return L("Model ontladen…")
        case .stopped: return L("Model niet geladen")
        }
    }

    static func family(_ f: String) -> Color { f == "glm" ? mint : (f == "qwen" ? amber : accent) }
    static func familyGradient(_ f: String) -> LinearGradient {
        switch f {
        case "glm": return LinearGradient(colors: [mint, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "qwen": return LinearGradient(colors: [amber, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        default: return LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Soft colour blobs behind everything. Still by default (a moving, brightening background is busy);
/// "Bewegende achtergrond" in the settings lets them drift and light up while the model writes.
struct AuroraBackground: View {
    var energy: Double = 0      // 0…1, from the live token rate (only used when animated)
    @AppStorage("animatedBackground") private var animated = false

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    canvas(t: tl.date.timeIntervalSinceReferenceDate * (0.05 + 0.10 * energy), energy: energy)
                }
            } else {
                canvas(t: 0, energy: 0)
            }
        }
        .ignoresSafeArea()
    }

    private func canvas(t: Double, energy: Double) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.night))
            let blobs: [(Color, Double, Double, Double)] = [
                (Theme.accent, 0.0, 0.55, 0.9), (Theme.violet, 2.1, 0.45, 0.8),
                (Theme.cyan, 4.2, 0.35, 0.6), (Theme.pink, 5.3, 0.30, 0.5),
            ]
            ctx.addFilter(.blur(radius: min(size.width, size.height) * 0.12))
            for (color, phase, radius, strength) in blobs {
                let x = size.width * (0.5 + 0.38 * sin(t * 0.9 + phase))
                let y = size.height * (0.5 + 0.34 * cos(t * 0.7 + phase * 1.3))
                let r = min(size.width, size.height) * radius
                let rect = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
                ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity((0.16 + 0.14 * energy) * strength)))
            }
        }
    }
}

/// A frosted glass card with a soft gradient edge.
struct GlassCard<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var glow: Color = Theme.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(glow).frame(width: 24, height: 24)
                            .background(glow.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Text(title).font(.system(.headline, design: .rounded))
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(LinearGradient(colors: [glow.opacity(0.55), .white.opacity(0.06), glow.opacity(0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: glow.opacity(0.12), radius: 18, y: 6)
    }
}

/// A ring gauge with an angular gradient and a glowing tip.
struct GaugeRing: View {
    var value: Double           // current
    var maximum: Double
    var label: String
    var unit: String
    var gradient = AngularGradient(colors: [Theme.cyan, Theme.accent, Theme.violet, Theme.pink, Theme.cyan], center: .center)
    var size: CGFloat = 200

    var body: some View {
        let fraction = min(max(value / maximum, 0), 1)
        ZStack {
            Circle().stroke(.white.opacity(0.06), style: StrokeStyle(lineWidth: size * 0.075))
            Circle()
                .trim(from: 0, to: fraction * 0.999)
                .stroke(gradient, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.accent.opacity(0.8), radius: 10)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fraction)
            // the number in the very middle of the ring, what belongs to it below that
            Text(value, format: .number.precision(.fractionLength(1)))
                .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: size * 0.72)
                .contentTransition(.numericText(value: value))
                .animation(.snappy, value: value)
                .foregroundStyle(Theme.cool)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 2) {
                        Text(unit).font(.system(size: size * 0.07, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        if !label.isEmpty {
                            Text(label).font(.system(size: size * 0.065, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary)
                        }
                    }
                    .fixedSize()
                    .alignmentGuide(.bottom) { $0[.top] }
                }
        }
        .frame(width: size, height: size)
    }
}

/// A moving highlight across text or a shape ("the model is busy").
struct Shimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: phase * geo.size.width * 1.5)
                            .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                    }
                }
            }
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// A pulsing glow ring around the assistant avatar while it writes (nothing at all otherwise).
struct PulseRing: View {
    var active: Bool

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let phase = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                Circle().stroke(Theme.brand, lineWidth: 2)
                    .scaleEffect(1 + 0.45 * phase)
                    .opacity(0.9 * (1 - phase))
            }
        }
    }
}

/// The app mark: a gradient orb with sparkles; it only turns while the model writes (an endless animation keeps the
/// window server busy and the fans spinning).
struct BrandMark: View {
    var size: CGFloat = 30
    var active = false

    var body: some View {
        ZStack {
            if active {
                TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                    orb.rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) * 120))
                }
            } else {
                orb
            }
            Circle().fill(Theme.night.opacity(0.35)).padding(size * 0.08)
            Image(systemName: "sparkles").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.violet.opacity(active ? 0.9 : 0.4), radius: active ? 12 : 6)
    }

    private var orb: some View {
        Circle().fill(AngularGradient(colors: [Theme.accent, Theme.violet, Theme.pink, Theme.cyan, Theme.accent], center: .center))
    }
}

extension UInt64 {
    var gbShort: String { String(format: "%.0f GB", Double(self) / 1e9) }
}
