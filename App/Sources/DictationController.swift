import AppKit
import ApplicationServices
import AVFoundation
import Combine
import TranscribeCore

/// App-side glue: EventTapEngine → DictationCoordinator → debug HUD/status item.
/// (The real pill HUD replaces the debug panel at M5.)
@MainActor
final class DictationController {
    let coordinator: DictationCoordinator
    private let engine = EventTapEngine(key: .fn)
    private let hud = DebugIntentHUD()
    private var cancellables: Set<AnyCancellable> = []

    var onStatusChange: ((String) -> Void)?

    init() {
        coordinator = DictationCoordinator(
            audioFactory: { AudioCaptureEngine() },
            transcription: StubTranscriptionService(),
            insertion: StubClipboardInserter(),
            contextProvider: {
                let app = NSWorkspace.shared.frontmostApplication
                return DictationContext(
                    targetAppBundleID: app?.bundleIdentifier,
                    targetAppName: app?.localizedName
                )
            }
        )
    }

    func start() {
        if !AXIsProcessTrusted() {
            Log.permissions.info("Accessibility not granted — prompting")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        // Mic permission must be resolved BEFORE the engine starts: an AVAudioEngine
        // with undetermined/denied mic access runs "successfully" while the tap
        // silently delivers zero buffers (M2 field bug).
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.permissions.info("microphone auth status: \(micStatus.rawValue) (3=authorized)")
        switch micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.permissions.info("microphone request resolved: \(granted)")
                Task { @MainActor [weak self] in
                    self?.onStatusChange?(granted ? "Ready — hold fn to dictate"
                                                  : "Microphone access is off — enable it in System Settings")
                }
            }
        case .denied, .restricted:
            onStatusChange?("Microphone access is off — enable it in System Settings → Privacy → Microphone")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default:
            break
        }

        engine.onIntent = { [weak self] intent in
            Task { @MainActor in
                self?.coordinator.handle(intent)
            }
        }

        if engine.start() {
            onStatusChange?("Ready — hold fn to dictate")
            hud.show()
        } else {
            onStatusChange?("Grant Accessibility to enable the dictation key")
        }

        bindHUD()

        if FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey {
            Log.hotkey.info("Globe key conflict — onboarding will prompt for 'Do Nothing'")
        }
        if FnUsageAdvisor.karabinerIsPresent() {
            Log.hotkey.warning("Karabiner-Elements detected — fn capture may conflict")
        }
    }

    private func bindHUD() {
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.hud.setPhase(Self.describe(state))
            }
            .store(in: &cancellables)

        coordinator.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.hud.setLevel(level)
            }
            .store(in: &cancellables)

        coordinator.$lastResult
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.hud.setResult(text)
            }
            .store(in: &cancellables)

        coordinator.$coachingHint
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hint in
                self?.hud.setPhase(hint)
            }
            .store(in: &cancellables)
    }

    private static func describe(_ state: DictationState) -> String {
        switch state {
        case .idle: return "idle"
        case .warming: return "warming"
        case .recording(let locked): return locked ? "recording (hands-free)" : "recording"
        case .finalizing: return "finalizing"
        case .transcribing: return "transcribing"
        case .inserting: return "inserting"
        case .done(let outcome): return "done: \(outcome)"
        case .cancelled: return "cancelled"
        case .failed(let failure): return "failed: \(failure)"
        }
    }
}
