import AppKit
import CoreAudio
import JotCore

/// Owns the NSStatusItem. Plain NSStatusItem (not MenuBarExtra) so the icon can be
/// animated per state: listening = equalizer bars, processing = sequential pulse.
/// Template-only rendering (menu bar convention; macOS shows its own mic dot).
final class StatusItemController: NSObject {
    enum VisualState {
        case idle
        case listening
        case processing
        case attention // permission missing / key invalid
    }

    private let statusItem: NSStatusItem
    private let onOpenHistory: () -> Void
    private let onPasteLast: () -> Void
    private let onOpenSettings: () -> Void
    private let onStartHandsFree: () -> Void
    private var animationTimer: Timer?
    private var frameIndex = 0
    private var state: VisualState = .idle

    init(
        onOpenHistory: @escaping () -> Void,
        onPasteLast: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onStartHandsFree: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.onOpenHistory = onOpenHistory
        self.onPasteLast = onPasteLast
        self.onOpenSettings = onOpenSettings
        self.onStartHandsFree = onStartHandsFree
        super.init()

        statusItem.button?.image = Self.glyph(barHeights: Self.idleBars, dimmed: false)
        statusItem.button?.toolTip = "Jot"
        statusItem.menu = makeMenu()
    }

    func setState(_ newState: VisualState) {
        guard newState != state else { return }
        state = newState
        animationTimer?.invalidate()
        animationTimer = nil
        frameIndex = 0

        switch newState {
        case .idle:
            statusItem.button?.image = Self.glyph(barHeights: Self.idleBars, dimmed: false)
        case .attention:
            statusItem.button?.image = Self.glyph(barHeights: Self.idleBars, dimmed: true)
        case .listening, .processing:
            let interval = newState == .listening ? 0.12 : 0.25
            animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.tickAnimation()
            }
            tickAnimation()
        }
    }

    private func tickAnimation() {
        frameIndex += 1
        let heights: [CGFloat]
        switch state {
        case .listening:
            heights = Self.listeningFrames[frameIndex % Self.listeningFrames.count]
        case .processing:
            heights = Self.processingFrames[frameIndex % Self.processingFrames.count]
        default:
            heights = Self.idleBars
        }
        statusItem.button?.image = Self.glyph(barHeights: heights, dimmed: false)
    }

    // MARK: - Glyph drawing (original mark: pill outline + 3 waveform bars)

    private static let idleBars: [CGFloat] = [3.5, 6, 3.5]
    private static let listeningFrames: [[CGFloat]] = [
        [3, 6.5, 4], [5, 4, 6], [6.5, 5.5, 3.5], [4, 7, 5], [3.5, 5, 6.5],
    ]
    private static let processingFrames: [[CGFloat]] = [
        [6, 4, 4], [4, 6, 4], [4, 4, 6], [4, 6, 4],
    ]

    private static func glyph(barHeights: [CGFloat], dimmed: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let alpha: CGFloat = dimmed ? 0.4 : 1.0
            let pill = NSBezierPath(
                roundedRect: NSRect(x: 1, y: 3.5, width: 16, height: 11),
                xRadius: 5.5, yRadius: 5.5
            )
            pill.lineWidth = 1.5
            NSColor.black.withAlphaComponent(alpha).setStroke()
            pill.stroke()

            let barWidth: CGFloat = 1.8
            let xs: [CGFloat] = [5.1, 8.1, 11.1]
            for (x, height) in zip(xs, barHeights) {
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: 9 - height / 2, width: barWidth, height: height),
                    xRadius: barWidth / 2, yRadius: barWidth / 2
                )
                NSColor.black.withAlphaComponent(alpha).setFill()
                bar.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Menu

    private var statusLine: NSMenuItem?

    func setStatusLine(_ text: String) {
        statusLine?.title = text
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Starting up…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusLine = status
        menu.addItem(status)

        menu.addItem(.separator())

        let handsFree = NSMenuItem(title: "Start Hands-Free Dictation", action: #selector(startHandsFree), keyEquivalent: "")
        handsFree.target = self
        menu.addItem(handsFree)

        let pasteLast = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLastTranscript), keyEquivalent: "")
        pasteLast.target = self
        menu.addItem(pasteLast)

        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        // Which mic Jot hears through — moves the SYSTEM default input, exactly
        // like Control Center, so AirPods vs built-in is one click (dogfood).
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu(title: "Microphone")
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Jot", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Jot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    @objc private func openHistory() {
        onOpenHistory()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func startHandsFree() {
        onStartHandsFree()
    }

    @objc private func pasteLastTranscript() {
        onPasteLast()
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID else { return }
        AudioInputDevices.setDefault(id: id)
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Rebuild the Microphone submenu each open — devices come and go
    /// (AirPods connect, headsets unplug) and the checkmark must be live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Microphone" else { return }
        menu.removeAllItems()
        let current = AudioInputDevices.currentDefaultID()
        let devices = AudioInputDevices.list()
        if devices.isEmpty {
            let none = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let note = NSMenuItem(title: "Sets your Mac's input device", action: nil, keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
    }
}
