import AppKit
import ApplicationServices
import TranscribeCore

/// M1 wiring: owns the EventTapEngine, requests Accessibility when missing, and
/// mirrors intents into the debug HUD + log. The DictationCoordinator replaces the
/// intent handler in M2+.
@MainActor
final class HotkeyDemo {
    private let engine = EventTapEngine(key: .fn)
    private let hud = DebugIntentHUD()
    private(set) var sessionActive = false

    var onStatusChange: ((String) -> Void)?

    func start() {
        if !AXIsProcessTrusted() {
            Log.permissions.info("Accessibility not granted — prompting")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        engine.onIntent = { [weak self] intent in
            Task { @MainActor in
                self?.handle(intent)
            }
        }
        engine.onTapRevived = {
            Log.hotkey.warning("tap revived")
        }

        if engine.start() {
            onStatusChange?("Ready — hold fn to test the grammar")
            hud.show()
            hud.setPhase("idle")
        } else {
            onStatusChange?("Grant Accessibility to enable the dictation key")
            Log.hotkey.error("engine did not start: \(String(describing: self.engine.state))")
        }

        let globeAction = FnUsageAdvisor.currentGlobeKeyAction()
        if globeAction.conflictsWithFnHotkey {
            Log.hotkey.info("Globe key action conflicts (\(String(describing: globeAction), privacy: .public)) — onboarding will prompt for 'Do Nothing'")
        }
        if FnUsageAdvisor.karabinerIsPresent() {
            Log.hotkey.warning("Karabiner-Elements detected — fn capture may conflict")
        }
    }

    private func handle(_ intent: HotkeyIntent) {
        switch intent {
        case .begin:
            sessionActive = true
        case .lockIn:
            sessionActive = true
        case .finalize, .cancel, .shortTapHint, .abortAccidental:
            sessionActive = false
        }
        let phase: String
        switch intent {
        case .begin: phase = "recording"
        case .lockIn: phase = "locked (hands-free)"
        case .finalize: phase = "finalize → idle"
        case .cancel: phase = "cancelled → idle"
        case .shortTapHint: phase = "hint: hold to talk — double-tap to lock"
        case .abortAccidental: phase = "aborted (accidental chord)"
        }
        hud.record(intent: intent, phase: phase)
        Log.hotkey.info("intent: \(String(describing: intent), privacy: .public)")
    }
}
