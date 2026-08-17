import AppKit
import TranscribeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var designPreviewWindow: DesignPreviewWindowController?
    private var dictationController: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FontLoader.registerBundledFonts()
        let controller = DictationController()
        statusItemController = StatusItemController(
            onOpenDesignPreview: { [weak self] in self?.openDesignPreview() },
            onOpenHistory: { [weak controller] in controller?.openHistory() },
            onPasteLast: { [weak controller] in controller?.pasteLastTranscript() },
            onOpenSettings: { [weak controller] in controller?.openSettings() },
            onStartHandsFree: { [weak controller] in controller?.startHandsFree() }
        )
        controller.onStatusChange = { [weak self] status in
            self?.statusItemController?.setStatusLine(status)
        }
        controller.onStatusItemState = { [weak self] state in
            self?.statusItemController?.setState(state)
        }
        controller.start()
        dictationController = controller
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
