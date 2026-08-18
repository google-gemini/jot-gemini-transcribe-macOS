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
            #if DEBUG
            // transcribe://set/<key>/<true|false> — flips a boolean setting through
            // the REAL SettingsStore setter (and its change notification), so the
            // live-update path can be exercised headlessly. Debug builds only.
            case "set":
                let parts = url.pathComponents
                if parts.count >= 3, let value = Bool(parts[2]) {
                    Self.applyDebugSetting(key: parts[1], value: value)
                }
            #endif
            default: Log.session.warning("unknown URL: \(urlString, privacy: .public)")
            }
        }
    }

    #if DEBUG
    private static func applyDebugSetting(key: String, value: Bool) {
        let settings = SettingsStore()
        switch key {
        case "showIdleIndicator": settings.setShowIdleIndicator(value)
        case "soundsEnabled": settings.setSoundsEnabled(value)
        case "smartFormatting": settings.setSmartFormatting(value)
        case "doubleTapLock": settings.setDoubleTapLock(value)
        default: Log.session.warning("debug set: unknown key \(key, privacy: .public)")
        }
    }
    #endif

}

extension Bundle {
    var buildNumber: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }
}
