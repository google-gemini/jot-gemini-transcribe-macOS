import AppKit
import TranscribeCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var dictationController: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerURLHandler()
        FontLoader.registerBundledFonts()
        let controller = DictationController()
        statusItemController = StatusItemController(
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

    /// transcribe:// URL scheme — Raycast/Shortcuts automation + headless UI checks.
    /// transcribe://settings[/general|dictation|privacy|advanced] | history | dictionary
    ///   | onboarding | start-hands-free | stop
    /// NOTE: registered via NSAppleEventManager in didFinishLaunching — the
    /// NSApplicationDelegate application(_:open:) path is NOT delivered under the
    /// SwiftUI App lifecycle.
    func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        let command = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let section = url.pathComponents.count > 1 ? url.pathComponents[1] : nil
        Log.session.info("URL command: \(command, privacy: .public)")
        Task { @MainActor [weak self] in
            switch command {
            case "settings":
                self?.dictationController?.openSettings(section: section)
            case "history": self?.dictationController?.openHistory()
            case "dictionary": self?.dictationController?.openDictionary()
            case "onboarding":
                self?.dictationController?.presentOnboardingManually()
                if let section, let index = Int(section) {
                    NotificationCenter.default.post(name: .onboardingJumpToScreen, object: index)
                }
            case "start-hands-free": self?.dictationController?.startHandsFree()
            case "stop": self?.dictationController?.coordinator.handle(.finalize)
            default: Log.session.warning("unknown URL: \(urlString, privacy: .public)")
            }
        }
    }

}

extension Bundle {
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
