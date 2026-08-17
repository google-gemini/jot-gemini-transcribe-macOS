import AppKit
import SwiftUI

/// Dev-only window that renders the token sheet: type scale in Google Sans Flex,
/// the GM3 palette, radii, springs. Lets us eyeball that fonts registered and the
/// look reads Google before the real HUD lands (M5).
final class DesignPreviewWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Design Preview"
        window.center()
        window.contentView = NSHostingView(rootView: DesignPreviewView())
        self.init(window: window)
    }
}

private struct DesignPreviewView: View {
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GT.Spacing.xl) {
                Group {
                    Text("Speak. It types.")
                        .font(GT.TypeScale.display(grad: grad))
                    Text("Headline — Google Sans Flex, ROND 15")
                        .font(GT.TypeScale.headline(grad: grad))
                    Text("Title — the quick brown fox jumps over the lazy dog")
                        .font(GT.TypeScale.title(grad: grad))
                    Text("Body large — Hold a key, say the thing, and polished text lands wherever your cursor is. 0123456789.")
                        .font(GT.TypeScale.bodyLarge(grad: grad))
                    Text("Label — HOLD FN TO DICTATE · 00:42")
                        .font(GT.TypeScale.numeric(grad: grad))
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                    Text("code — AIzaSy…your-key-here (Google Sans Code)")
                        .font(GT.TypeScale.code)
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                }

                Divider()

                Text("Palette").font(GT.TypeScale.title(grad: grad))
                HStack(spacing: GT.Spacing.xs) {
                    swatch("primary", GT.Colors.primary)
                    swatch("container", GT.Colors.primaryContainer)
                    swatch("surface", GT.Colors.surfaceContainer)
                    swatch("error", GT.Colors.errorContainer)
                    swatch("success", GT.Colors.success)
                }
                HStack(spacing: GT.Spacing.xs) {
                    ForEach(Array(GT.Colors.brandQuad.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: GT.Radius.xs)
                            .fill(color)
                            .frame(width: 44, height: 24)
                    }
                    Text("brand quad — waveform/processing only")
                        .font(GT.TypeScale.labelSmall(grad: grad))
                        .foregroundStyle(GT.Colors.onSurfaceVariant)
                }

                Divider()

                Text("Pill silhouette").font(GT.TypeScale.title(grad: grad))
                PillMock()
            }
            .padding(GT.Spacing.xxl)
        }
        .background(GT.Colors.windowBackground)
        .foregroundStyle(GT.Colors.onSurface)
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: GT.Spacing.xxs) {
            RoundedRectangle(cornerRadius: GT.Radius.small)
                .fill(color)
                .frame(width: 88, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: GT.Radius.small)
                        .strokeBorder(GT.Colors.outlineVariant.opacity(0.4), lineWidth: 1)
                )
            Text(name).font(GT.TypeScale.labelSmall())
                .foregroundStyle(GT.Colors.onSurfaceVariant)
        }
    }
}

/// Static mock of the listening pill — real component arrives at M5.
private struct PillMock: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(GT.Colors.gBlue)
                    .frame(width: 6, height: [14, 24, 32, 20, 10][index])
            }
        }
        .frame(width: 200, height: 48)
        .background(
            Capsule().fill(GT.Colors.surface)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 2)
        )
        .overlay(Capsule().strokeBorder(GT.Colors.outlineVariant.opacity(0.08), lineWidth: 1))
    }
}
