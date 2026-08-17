import AppKit
import SwiftUI
import TranscribeCore

/// M1 debug surface: a floating, non-activating bottom-center panel that shows the
/// hotkey grammar working from any app. The real pill (M5) replaces its content;
/// the panel plumbing (non-activating, all-Spaces, no focus stealing) is final.
@MainActor
final class DebugIntentHUD {
    final class Model: ObservableObject {
        @Published var phase: String = "idle"
        @Published var events: [String] = []
        @Published var level: Float = 0
        @Published var result: String?
    }

    let model = Model()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DebugIntentView(model: model))
        reposition()
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setPhase(_ phase: String) {
        model.phase = phase
        let stamp = Date().formatted(date: .omitted, time: .standard)
        model.events.insert("\(stamp)  \(phase)", at: 0)
        model.events = Array(model.events.prefix(4))
    }

    func setLevel(_ level: Float) {
        model.level = level
    }

    func setResult(_ text: String) {
        model.result = text
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 24
        ))
    }
}

private struct DebugIntentView: View {
    @ObservedObject var model: DebugIntentHUD.Model

    var body: some View {
        VStack(spacing: GT.Spacing.xxs) {
            HStack(spacing: GT.Spacing.xs) {
                Circle()
                    .fill(model.phase == "idle" ? GT.Colors.onSurfaceVariant : GT.Colors.gBlue)
                    .frame(width: 8, height: 8)
                Text(model.phase)
                    .font(GT.TypeScale.label())
                    .foregroundStyle(GT.Colors.onSurface)
                // Simple live level bar (real waveform arrives at M5).
                Capsule()
                    .fill(GT.Colors.gBlue)
                    .frame(width: max(2, CGFloat(model.level) * 80), height: 4)
                    .animation(GTMotion.fastEffects, value: model.level)
            }
            if let result = model.result {
                Text(result)
                    .font(GT.TypeScale.labelSmall())
                    .foregroundStyle(GT.Colors.onSurface)
                    .lineLimit(1)
            }
            ForEach(model.events, id: \.self) { line in
                Text(line)
                    .font(GT.TypeScale.labelSmall())
                    .foregroundStyle(GT.Colors.onSurfaceVariant)
            }
        }
        .padding(.horizontal, GT.Spacing.m)
        .padding(.vertical, GT.Spacing.xs)
        .frame(minWidth: 260)
        .background(
            RoundedRectangle(cornerRadius: GT.Radius.large)
                .fill(GT.Colors.surface)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GT.Radius.large)
                .strokeBorder(GT.Colors.outlineVariant.opacity(0.3), lineWidth: 1)
        )
    }
}
