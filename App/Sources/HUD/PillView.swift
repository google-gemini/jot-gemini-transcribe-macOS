import SwiftUI
import TranscribeCore

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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription)
    }

    private var spatial: Animation {
        reduceMotion ? .linear(duration: 0.15) : GTMotion.expressiveDefaultSpatial
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()

        case .idleDot:
            Capsule()
                .fill(GT.Colors.onSurfaceVariant.opacity(0.18))
                .frame(width: 40, height: 8)
                .gtGlassCapsule()
                .padding(.vertical, 20) // stable panel hit area

        case .listening(let locked):
            pillSurface(width: locked ? 268 : 200) {
                HStack(spacing: GT.Spacing.s) {
                    if locked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(GT.Colors.onSurfaceVariant)
                        Text(timerText)
                            .font(GT.TypeScale.numeric())
                            .foregroundStyle(GT.Colors.onSurfaceVariant)
                    } else if model.elapsed >= 10 {
                        Text(timerText)
                            .font(GT.TypeScale.numeric())
                            .foregroundStyle(GT.Colors.onSurfaceVariant)
                    }
                    WaveformView(level: model.level, processing: false)
                    if locked {
                        stopButton
                    }
                }
            }

        case .processing:
            pillSurface(width: model.slow ? 220 : 132) {
                HStack(spacing: GT.Spacing.s) {
                    WaveformView(level: 0, processing: true)
                    if model.slow {
                        Text("Still working…")
                            .font(GT.TypeScale.label())
                            .foregroundStyle(GT.Colors.onSurfaceVariant)
                            .transition(.opacity)
                    }
                }
            }

        case .success(let words):
            successBadge(words: words)

        case .notice(let message):
            pillSurface(width: nil) {
                Text(message)
                    .font(GT.TypeScale.label())
                    .foregroundStyle(GT.Colors.onSurface)
                    .lineLimit(1)
                    .padding(.horizontal, GT.Spacing.xxs)
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
            .padding(.horizontal, GT.Spacing.m)
            .frame(width: width, height: 48)
            .frame(maxWidth: width == nil ? 320 : nil)
            .gtGlassCapsule(tint: tint)
    }

    private var stopButton: some View {
        Button {
            NotificationCenter.default.post(name: .pillStopTapped, object: nil)
        } label: {
            ZStack {
                Circle().fill(GT.Colors.primary)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(GT.Colors.onPrimary)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop dictation and insert text")
    }

    private func successBadge(words: Int?) -> some View {
        VStack(spacing: GT.Spacing.xxs) {
            CheckmarkShape()
                .trim(from: 0, to: 1)
                .stroke(GT.Colors.success, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20)
                .frame(width: 48, height: 48)
                .gtGlassCircle()
            if let words, words > 20 {
                Text("\(words) words")
                    .font(GT.TypeScale.labelSmall())
                    .foregroundStyle(GT.Colors.onSurfaceVariant)
            }
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func errorChip(message: String) -> some View {
        HStack(spacing: GT.Spacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(GT.Colors.onErrorContainer)
            Text(message)
                .font(GT.TypeScale.label())
                .foregroundStyle(GT.Colors.onErrorContainer)
                .lineLimit(1)
        }
        .padding(.horizontal, GT.Spacing.m)
        .frame(height: 48)
        .frame(maxWidth: 320)
        .gtGlassCapsule(tint: GT.Colors.errorContainer)
        .modifier(ShakeEffect(shakes: reduceMotion ? 0 : 3))
    }

    private var timerText: String {
        let seconds = Int(model.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityDescription: String {
        switch model.state {
        case .hidden, .idleDot: return "Google Transcribe — ready"
        case .listening(true): return "Listening — hands-free locked"
        case .listening(false): return "Listening"
        case .processing: return "Processing"
        case .success(let words): return "Inserted\(words.map { " \($0) words" } ?? "")"
        case .notice(let message): return message
        case .error(let message): return "Error — \(message)"
        }
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
                    .fill(tint ?? GT.Colors.surface)
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
                    .fill(GT.Colors.surface)
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
    static let pillStopTapped = Notification.Name("com.google.transcribe.pill.stop")
}
