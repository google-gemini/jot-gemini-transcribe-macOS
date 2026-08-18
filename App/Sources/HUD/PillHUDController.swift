import AppKit
import SwiftUI
import JotCore

/// Owns the non-activating NSPanel that hosts the pill. Fixed-size panel; the pill
/// animates its own bounds inside (avoids NSWindow frame-animation jank).
/// The panel never becomes key except transiently for the locked-state stop button.
@MainActor
final class PillHUDController {
    let model = PillModel()
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 96),
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
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(
            rootView: PillRootView(model: model)
        )
        reposition()
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    /// Called at each session start so the pill follows the display the user is
    /// actually dictating on (audit L14 — it used to stick to the launch screen).
    func repositionToActiveScreen() {
        reposition()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Bottom-center of the screen hosting the FOCUSED window — where the text
    /// will actually land. Mouse position is only a fallback: keyboard-first
    /// users routinely dictate on one display with the pointer parked on
    /// another (production pass 2). Doesn't jump mid-session (spec §1.1).
    private func reposition() {
        let screen = Self.screenOfFocusedWindow()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 16
        ))
    }

    /// AX lookup of the frontmost app's focused window midpoint → its screen.
    /// 100ms messaging timeout: a hung app degrades to the mouse fallback
    /// instead of stalling session start.
    private static func screenOfFocusedWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(windowRef as AnyObject, to: AXUIElement.self)
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              AXValueGetValue(unsafeDowncast(posRef as AnyObject, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeRef as AnyObject, to: AXValue.self), .cgSize, &size) else { return nil }
        // AX coords are top-left-origin global; flip into Cocoa screen space.
        guard let primary = NSScreen.screens.first else { return nil }
        let midAX = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let cocoaPoint = NSPoint(x: midAX.x, y: primary.frame.maxY - midAX.y)
        return NSScreen.screens.first(where: { $0.frame.contains(cocoaPoint) })
    }
}

private struct PillRootView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            PillView(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 8)
    }
}
