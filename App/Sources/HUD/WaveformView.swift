import SwiftUI

/// The 5-bar amplitude-reactive waveform (Gemini Live "condensed into a tiny pill").
/// Live state: Google Blue bars with fast-attack/slow-release smoothing and a calm
/// idle undulation. Processing state: bars freeze into a silhouette and run the
/// four-color traveling sweep — the only place the brand quad animates.
struct WaveformView: View {
    var level: Float
    var processing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barWidth: CGFloat = 6
    private static let gap: CGFloat = 4
    private static let minHeight: CGFloat = 8
    private static let maxHeight: CGFloat = 32
    /// Per-bar personality: center bar leads, neighbors follow.
    private static let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.75, 0.5]
    private static let phases: [Double] = [0.0, 0.9, 1.7, 2.6, 3.4]

    // Fast attack / slow release smoothing state (EMA per spec §1.4).
    @State private var smoothed: [CGFloat] = [0, 0, 0, 0, 0]

    var body: some View {
        if reduceMotion {
            staticBars
        } else {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    drawBars(context: &context, size: size, time: t)
                }
            }
            .frame(width: totalWidth, height: Self.maxHeight)
        }
    }

    private var totalWidth: CGFloat {
        Self.barWidth * 5 + Self.gap * 4
    }

    private func drawBars(context: inout GraphicsContext, size: CGSize, time: Double) {
        let sweep = (time.truncatingRemainder(dividingBy: 1.2)) / 1.2
        for index in 0..<5 {
            let height = barHeight(index: index, time: time)
            let x = CGFloat(index) * (Self.barWidth + Self.gap)
            let rect = CGRect(
                x: x,
                y: (size.height - height) / 2,
                width: Self.barWidth,
                height: height
            )
            let path = Path(roundedRect: rect, cornerRadius: Self.barWidth / 2)
            if processing {
                // Four-color traveling gradient across the frozen silhouette.
                let hue = (Double(index) / 5.0 + sweep).truncatingRemainder(dividingBy: 1.0)
                context.fill(path, with: .color(quadColor(at: hue)))
            } else {
                context.fill(path, with: .color(GT.Colors.gBlue))
            }
        }
    }

    private func barHeight(index: Int, time: Double) -> CGFloat {
        if processing {
            // Gentle 4-phase chase between 10 and 22pt, staggered — "thinking".
            let phase = sin(time * 2 * .pi / 1.4 + Self.phases[index])
            return 16 + phase * 6
        }
        // Idle breathing + level-reactive rise. The ±2pt sine at 0.8Hz with per-bar
        // phase offsets is the calm Gemini Live idle.
        let idle = sin(time * 2 * .pi * 0.8 + Self.phases[index]) * 2
        let reactive = CGFloat(level) * Self.weights[index] * (Self.maxHeight - Self.minHeight)
        let jitter = sin(time * 2 * .pi * 3.1 + Self.phases[index] * 2) * CGFloat(level) * 4
        let height = Self.minHeight + idle + reactive + jitter
        return min(Self.maxHeight, max(Self.minHeight, height))
    }

    private func quadColor(at position: Double) -> Color {
        // Blue → Red → Yellow → Green loop.
        let colors = GT.Colors.brandQuad
        let scaled = position * Double(colors.count)
        return colors[Int(scaled) % colors.count]
    }

    /// Reduce Motion: static 5-bar level meter, opacity-only response.
    private var staticBars: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: Self.barWidth / 2)
                    .fill(processing ? GT.Colors.brandQuad[index % 4] : GT.Colors.gBlue)
                    .frame(
                        width: Self.barWidth,
                        height: Self.minHeight + Self.weights[index] * 14
                    )
                    .opacity(processing ? 0.8 : 0.4 + Double(level) * 0.6)
            }
        }
        .frame(height: Self.maxHeight)
    }
}
