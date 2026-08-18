import SwiftUI
import JotCore

/// The pill — geometry, states, and transitions per docs/design/experience.md §1.
/// Heights 48pt (full pill), state-specific widths, M3 motion tokens throughout:
/// spatial springs move things, effects springs fade things, expressive springs
/// only on hero moments (appear, lock, success).
struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(spatial, value: model.state)
            // States with real controls (Dictate dot, Stop button) must expose
            // their children or VoiceOver users can't stop a locked recording.
            .accessibilityElement(children: hasInteractiveControls ? .contain : .ignore)
            .accessibilityLabel(accessibilityDescription)
    }

    private var hasInteractiveControls: Bool {
        switch model.state {
        case .idleDot, .listening(locked: true): return true
        default: return false
        }
    }

    private var spatial: Animation {
        reduceMotion ? .linear(duration: 0.15) : JotMotion.expressiveDefaultSpatial
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()

        case .idleDot:
            IdleDotView()
                .padding(.vertical, 20) // stable panel hit area

        case .listening(let locked):
            pillSurface(width: locked ? 268 : 200) {
                HStack(spacing: JotUI.Spacing.s) {
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        Text(timerText)
                            .font(JotUI.TypeScale.numeric())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    } else if model.elapsed >= 10 {
                        Text(timerText)
                            .font(JotUI.TypeScale.numeric())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                    }
                    WaveformView(level: model.level, processing: false)
                    if locked {
                        stopButton
                    }
                }
            }

        case .processing:
            pillSurface(width: model.slow ? 220 : 132) {
                HStack(spacing: JotUI.Spacing.s) {
                    WaveformView(level: 0, processing: true)
                    if model.slow {
                        Text("Still working…")
                            .font(JotUI.TypeScale.label())
                            .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                            .transition(.opacity)
                    }
                }
            }

        case .success(let words):
            successBadge(words: words)

        case .notice(let message):
            pillSurface(width: nil) {
                Text(message)
                    .font(JotUI.TypeScale.label())
                    .foregroundStyle(JotUI.Colors.onSurface)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false) // never truncate — the pill hugs the text
                    .padding(.horizontal, JotUI.Spacing.xxs)
            }

        case .error(let message):
            errorChip(message: message)
        }
    }

    // MARK: - Pieces

    /// Liquid Glass on macOS 26+ (the pill is transient functional UI — exactly
    /// where the HIG wants glass); a plain Material-surface capsule earlier.
    /// No borders, no edge glows — the glass edge is the only edge.
    private func pillSurface<Content: View>(
        width: CGFloat?,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, JotUI.Spacing.m)
            .frame(width: width, height: 48)
            .frame(maxWidth: width == nil ? 560 : nil)
            .gtGlassCapsule(tint: tint)
    }

    private var stopButton: some View {
        Button {
            NotificationCenter.default.post(name: .pillStopTapped, object: nil)
        } label: {
            ZStack {
                Circle().fill(JotUI.Colors.primary)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(JotUI.Colors.onPrimary)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop dictation and insert text")
    }

    private func successBadge(words: Int?) -> some View {
        VStack(spacing: JotUI.Spacing.xxs) {
            CheckmarkShape()
                .trim(from: 0, to: 1)
                .stroke(JotUI.Colors.success, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20)
                .frame(width: 48, height: 48)
                .gtGlassCircle()
            if let words, words > 20 {
                Text("\(words) words")
                    .font(JotUI.TypeScale.labelSmall())
                    .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func errorChip(message: String) -> some View {
        HStack(spacing: JotUI.Spacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(JotUI.Colors.onErrorContainer)
            Text(message)
                .font(JotUI.TypeScale.label())
                .foregroundStyle(JotUI.Colors.onErrorContainer)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, JotUI.Spacing.m)
        .frame(height: 48)
        .frame(maxWidth: 560)
        .gtGlassCapsule(tint: JotUI.Colors.errorContainer)
        .modifier(ShakeEffect(shakes: reduceMotion ? 0 : 3))
    }

    private var timerText: String {
        let seconds = Int(model.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityDescription: String {
        switch model.state {
        case .hidden, .idleDot: return "Jot — ready"
        case .listening(true): return "Listening — hands-free locked"
        case .listening(false): return "Listening"
        case .processing: return "Processing"
        case .success(let words): return "Inserted\(words.map { " \($0) words" } ?? "")"
        case .notice(let message): return message
        case .error(let message): return "Error — \(message)"
        }
    }
}

// MARK: - Idle dot (the invitation)

/// At rest: a whisper of a capsule. On hover: the SAME capsule inflates into a
/// mini pill offering dictation — one view identity, one glass surface, so the
/// shape morphs continuously instead of cutting between two views. The content
/// blooms in a beat after the surface starts stretching (scale + blur-in), and
/// the springs are asymmetric: wobbly bloom out, calm settle back. Click starts
/// hands-free.
private struct IdleDotView: View {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The goo: low damping + longer response = visible squish and overshoot.
    private static let bloom = Animation.spring(response: 0.45, dampingFraction: 0.55)
    /// The retreat: goo relaxing, no wobble.
    private static let settle = Animation.spring(response: 0.30, dampingFraction: 0.85)
    /// Content arrives after the surface is already stretching.
    private static let contentBloom = Animation.spring(response: 0.34, dampingFraction: 0.7).delay(0.05)

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .pillDotTapped, object: nil)
        } label: {
            HStack(spacing: JotUI.Spacing.xs) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JotUI.Colors.gBlue)
                Text("Dictate")
                    .font(JotUI.TypeScale.label())
                    .foregroundStyle(JotUI.Colors.onSurface)
                    .fixedSize()
            }
            .opacity(hovering ? 1 : 0)
            .scaleEffect(hovering ? 1 : 0.4)
            .blur(radius: hovering || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? .linear(duration: 0.15) : (hovering ? Self.contentBloom : Self.settle), value: hovering)
            // One frame, continuously morphed — never two views.
            .frame(width: hovering ? 116 : 40, height: hovering ? 34 : 8)
            .background(
                Capsule()
                    .fill(JotUI.Colors.onSurfaceVariant.opacity(hovering ? 0.04 : 0.18))
            )
            .gtGlassCapsule()
            .contentShape(Capsule().scale(hovering ? 1.2 : 2.4)) // generous hit + hover target
            .animation(reduceMotion ? .linear(duration: 0.15) : (hovering ? Self.bloom : Self.settle), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start hands-free dictation")
        .accessibilityLabel("Start hands-free dictation")
    }
}

// MARK: - Glass surface (macOS 26+) with Material fallback

extension View {
    /// Borderless capsule surface: Liquid Glass on macOS 26+, surface+shadow before.
    @ViewBuilder
    func gtGlassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint.opacity(0.85)), in: .capsule)
            } else {
                self.glassEffect(.regular, in: .capsule)
            }
        } else {
            self.background(
                Capsule()
                    .fill(tint ?? JotUI.Colors.surface)
                    .shadow(color: .black.opacity(0.20), radius: 12, y: 2)
            )
        }
    }

    @ViewBuilder
    func gtGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self.background(
                Circle()
                    .fill(JotUI.Colors.surface)
                    .shadow(color: .black.opacity(0.20), radius: 12, y: 2)
            )
        }
    }
}

// MARK: - Effects

/// The one deliberately non-M3 gesture: a subtle ±4pt horizontal shake on error.
private struct ShakeEffect: ViewModifier {
    var shakes: Int
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .offset(x: animating ? 0 : 0)
            .modifier(ShakeGeometry(travel: 4, shakes: CGFloat(shakes), progress: animating ? 1 : 0))
            .onAppear {
                withAnimation(.timingCurve(0.36, 0.07, 0.19, 0.97, duration: 0.25)) {
                    animating = true
                }
            }
    }
}

private struct ShakeGeometry: GeometryEffect {
    var travel: CGFloat
    var shakes: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(progress * .pi * shakes * 2), y: 0
        ))
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.05, y: rect.midY + rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.02, y: rect.minY + rect.height * 0.15))
        return path
    }
}

extension Notification.Name {
    static let pillStopTapped = Notification.Name("com.ammaar.jot.pill.stop")
    static let pillDotTapped = Notification.Name("com.ammaar.jot.pill.dot")
}
