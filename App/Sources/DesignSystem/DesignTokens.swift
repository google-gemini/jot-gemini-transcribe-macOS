import SwiftUI
import AppKit

/// GT — the Google Transcribe design tokens. Every color, type style, radius,
/// spacing and state-layer value in the app comes from here; views contain no
/// magic values. Contract: docs/design/experience.md §3 (GM3 production values).
enum GT {

    // MARK: - Color

    enum Colors {
        // Accent
        static let primary = dyn(light: 0x0B57D0, dark: 0xA8C7FA)
        static let onPrimary = dyn(light: 0xFFFFFF, dark: 0x062E6F)
        static let primaryContainer = dyn(light: 0xD3E3FD, dark: 0x0842A0)
        static let onPrimaryContainer = dyn(light: 0x041E49, dark: 0xD3E3FD)

        // Surfaces (never pure black)
        static let surface = dyn(light: 0xFFFFFF, dark: 0x1E1F20)
        static let surfaceContainer = dyn(light: 0xF0F4F9, dark: 0x28292A)
        static let windowBackground = dyn(light: 0xF8FAFD, dark: 0x131314)
        static let onSurface = dyn(light: 0x1F1F1F, dark: 0xE3E3E3)
        static let onSurfaceVariant = dyn(light: 0x444746, dark: 0xC4C7C5)
        static let outline = dyn(light: 0x747775, dark: 0x8E918F)
        static let outlineVariant = dyn(light: 0xC4C7C5, dark: 0x444746)

        // Status
        static let error = dyn(light: 0xB3261E, dark: 0xF2B8B5)
        static let errorContainer = dyn(light: 0xF9DEDC, dark: 0x8C1D18)
        static let onErrorContainer = dyn(light: 0x410E0B, dark: 0xF9DEDC)
        static let success = dyn(light: 0x146C2E, dark: 0x6DD58C)

        // Brand quad — waveform, processing sweep, and celebration ONLY.
        static let gBlue = Color(hex: 0x4285F4)
        static let gRed = Color(hex: 0xEA4335)
        static let gYellow = Color(hex: 0xFBBC04)
        static let gGreen = Color(hex: 0x34A853)
        static let brandQuad: [Color] = [gBlue, gRed, gYellow, gGreen]
        /// The classic "AI shimmer" — appears exclusively in the processing state.
        static let aiShimmer: [Color] = [Color(hex: 0x4285F4), Color(hex: 0x9B72CB), Color(hex: 0xD96570)]

        private static func dyn(light: UInt32, dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    // MARK: - State layers (opacity of the on-color)

    enum StateLayer {
        static let hover: Double = 0.08
        static let focus: Double = 0.10
        static let pressed: Double = 0.10
        static let dragged: Double = 0.16
    }

    // MARK: - Shape

    enum Radius {
        static let xs: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xl: CGFloat = 28
        /// Stadium/pill — pass the view's height/2.
        static func full(for height: CGFloat) -> CGFloat { height / 2 }
    }

    // MARK: - Spacing (4pt grid)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 40
    }

    // MARK: - Type (Google Sans Flex / Google Sans Code, variable axes)

    enum TypeScale {
        // ROND stays 0 everywhere (the font's straight default) — dogfood verdict:
        // the rounded terminals read too soft; straight is the look.
        static func display(grad: CGFloat = 0) -> Font { GTFont.flex(32, weight: 400, grad: grad) }
        static func headline(grad: CGFloat = 0) -> Font { GTFont.flex(24, weight: 400, grad: grad) }
        static func title(grad: CGFloat = 0) -> Font { GTFont.flex(16, weight: 500, grad: grad) }
        /// History transcripts (16/24).
        static func bodyLarge(grad: CGFloat = 0) -> Font { GTFont.flex(16, weight: 400, grad: grad) }
        static func body(grad: CGFloat = 0) -> Font { GTFont.flex(14, weight: 400, grad: grad) }
        /// Pill status text.
        static func label(grad: CGFloat = 0) -> Font { GTFont.flex(12, weight: 500, grad: grad) }
        static func labelSmall(grad: CGFloat = 0) -> Font { GTFont.flex(11, weight: 500, grad: grad) }
        /// Timers/stats — label + tabular figures (apply .monospacedDigit()).
        static func numeric(grad: CGFloat = 0) -> Font { GTFont.flex(12, weight: 500, grad: grad).monospacedDigit() }
        /// API key / endpoint fields.
        static let code: Font = GTFont.sansCode(13, weight: 400)
    }
}

// MARK: - Variable-font plumbing

enum GTFont {
    // OpenType variation axis tags.
    private static let wght: UInt32 = 0x77676874
    private static let opsz: UInt32 = 0x6F70737A
    private static let GRAD: UInt32 = 0x47524144
    private static let ROND: UInt32 = 0x524F4E44

    static let flexPostScriptName = "GoogleSansFlex-Regular"
    static let codePostScriptName = "GoogleSansCode-Regular"

    /// Google Sans Flex with explicit axes. opsz is FLOORED at 17: the low-opsz
    /// masters that size-tracking would select for 11–14pt UI text are deliberately
    /// chunkier and rounder for small print — flooring keeps every UI size on the
    /// straighter text master (dogfood + google-design.md "UI at opsz ~17").
    /// Pass grad +25 in dark mode to thicken strokes without layout shift.
    static func flex(_ size: CGFloat, weight: CGFloat, grad: CGFloat = 0, rond: CGFloat = 0) -> Font {
        variable(flexPostScriptName, size: size, variations: [
            wght: weight,
            opsz: min(max(size, 17), 144),
            GRAD: grad,
            ROND: rond,
        ])
    }

    static func sansCode(_ size: CGFloat, weight: CGFloat) -> Font {
        variable(codePostScriptName, size: size, variations: [wght: weight])
    }

    private static func variable(_ postScriptName: String, size: CGFloat, variations: [UInt32: CGFloat]) -> Font {
        let axes = variations.reduce(into: [NSNumber: NSNumber]()) { dict, entry in
            dict[NSNumber(value: entry.key)] = NSNumber(value: Double(entry.value))
        }
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: postScriptName,
            kCTFontVariationAttribute: axes,
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let ctFont = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return Font(ctFont as NSFont)
    }
}

// MARK: - Hex helpers

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
