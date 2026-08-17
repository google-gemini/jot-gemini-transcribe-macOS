import AppKit

/// Owns the NSStatusItem. Plain NSStatusItem (not MenuBarExtra) so the icon can be
/// animated per state later (listening equalizer, processing pulse, queue badge).
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onOpenDesignPreview: () -> Void

    init(onOpenDesignPreview: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onOpenDesignPreview = onOpenDesignPreview
        super.init()

        statusItem.button?.image = Self.makeGlyph()
        statusItem.button?.toolTip = "Google Transcribe"
        statusItem.menu = makeMenu()
    }

    /// The menu bar mark: an original pill outline holding three waveform bars.
    /// Deliberately NOT the Gemini spark or any Google logo (see THIRD_PARTY_NOTICES).
    private static func makeGlyph() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let pill = NSBezierPath(
                roundedRect: NSRect(x: 1, y: 3.5, width: 16, height: 11),
                xRadius: 5.5, yRadius: 5.5
            )
            pill.lineWidth = 1.5
            NSColor.black.setStroke()
            pill.stroke()

            // Three bars, middle tallest — the waveform at rest.
            let barWidth: CGFloat = 1.8
            let heights: [CGFloat] = [3.5, 6, 3.5]
            let xs: [CGFloat] = [5.1, 8.1, 11.1]
            for (x, height) in zip(xs, heights) {
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: 9 - height / 2, width: barWidth, height: height),
                    xRadius: barWidth / 2, yRadius: barWidth / 2
                )
                NSColor.black.setFill()
                bar.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Setting up — dictation coming in M4", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let preview = NSMenuItem(title: "Design Preview…", action: #selector(openDesignPreview), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Google Transcribe", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Google Transcribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    @objc private func openDesignPreview() {
        onOpenDesignPreview()
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
