import AppKit
import TranscribeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var designPreviewWindow: DesignPreviewWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FontLoader.registerBundledFonts()
        statusItemController = StatusItemController(
            onOpenDesignPreview: { [weak self] in self?.openDesignPreview() }
        )
        Log.session.info("Google Transcribe launched (build \(Bundle.main.buildNumber, privacy: .public))")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func openDesignPreview() {
        if designPreviewWindow == nil {
            designPreviewWindow = DesignPreviewWindowController()
        }
        designPreviewWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Bundle {
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
