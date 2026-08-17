import AppKit
import ApplicationServices
import AVFoundation
import Combine
import TranscribeCore

/// App-side glue: EventTapEngine → DictationCoordinator → pill HUD + earcons +
/// status item. All HUD timing lives here (experience spec is canonical).
@MainActor
final class DictationController {
    let coordinator: DictationCoordinator
    private let engine = EventTapEngine(key: .fn)
    private let hud = PillHUDController()
    private let earcons = EarconPlayer()
    private var cancellables: Set<AnyCancellable> = []

    private var previousState: DictationState = .idle
    private var sessionStartedAt: Date?
    private var elapsedTimer: Timer?
    private var slowTimer: Timer?
    private var dismissTask: Task<Void, Never>?

    var onStatusChange: ((String) -> Void)?
    var onStatusItemState: ((StatusItemController.VisualState) -> Void)?

    init() {
        KeychainStore.migrateDevKeyFileIfPresent()
        let client = GeminiClient(apiKey: { KeychainStore.loadAPIKey() })
        coordinator = DictationCoordinator(
            audioFactory: { AudioCaptureEngine() },
            transcription: GeminiTranscriptionService(client: client),
            insertion: InsertionCoordinator(),
            contextProvider: {
                let app = NSWorkspace.shared.frontmostApplication
                return DictationContext(
                    targetAppBundleID: app?.bundleIdentifier,
                    targetAppName: app?.localizedName,
                    targetPID: app?.processIdentifier
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
        resolveMicPermission()

        engine.setDoubleTapLockEnabled(SettingsStore().doubleTapLockEnabled)
        engine.onIntent = { [weak self] intent in
            Task { @MainActor in
                self?.coordinator.handle(intent)
            }
        }

        NotificationCenter.default.addObserver(forName: .pillStopTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.coordinator.handle(.finalize)
            }
        }

        if engine.start() {
            onStatusChange?(KeychainStore.loadAPIKey() == nil
                ? "Add your Gemini API key (~/.config/google-transcribe/apikey.dev until Settings lands)"
                : "Ready — hold fn to dictate")
            hud.show()
        } else {
            onStatusChange?("Grant Accessibility to enable the dictation key")
        }

        bind()

        if FnUsageAdvisor.currentGlobeKeyAction().conflictsWithFnHotkey {
            Log.hotkey.info("Globe key conflict — onboarding will prompt for 'Do Nothing'")
        }
        if FnUsageAdvisor.karabinerIsPresent() {
            Log.hotkey.warning("Karabiner-Elements detected — fn capture may conflict")
        }
    }

    // MARK: - State → HUD/earcons (frame-synced: sound fires on the same tick)

    private func bind() {
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.transition(to: state)
            }
            .store(in: &cancellables)

        coordinator.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.hud.model.level = level
            }
            .store(in: &cancellables)

        coordinator.$coachingHint
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hint in
                self?.showNotice(hint, for: 3.0, sound: nil)
            }
            .store(in: &cancellables)
    }

    private func transition(to state: DictationState) {
        defer { previousState = state }
        dismissTask?.cancel()

        switch state {
        case .idle:
            setPill(.idleDot)
            onStatusItemState?(.idle)

        case .warming:
            sessionStartedAt = Date()
            earcons.play(.start)
            setPill(.listening(locked: false))
            startElapsedTimer()
            onStatusItemState?(.listening)

        case .recording(let locked):
            if case .recording(false) = previousState, locked {
                earcons.play(.lock)
            }
            setPill(.listening(locked: locked))
            onStatusItemState?(.listening)

        case .finalizing:
            earcons.play(.stop)
            stopElapsedTimer()
            setPill(.processing)
            armSlowTimer()
            onStatusItemState?(.processing)

        case .transcribing, .inserting:
            setPill(.processing)
            onStatusItemState?(.processing)

        case .done(let outcome):
            clearSlowTimer()
            onStatusItemState?(.idle)
            handleOutcome(outcome)

        case .cancelled:
            clearSlowTimer()
            stopElapsedTimer()
            onStatusItemState?(.idle)
            // Short accidental taps stay silent; deliberate cancels get the soft damp.
            if let startedAt = sessionStartedAt, Date().timeIntervalSince(startedAt) > 0.5 {
                earcons.play(.cancel)
            }
            setPill(.idleDot)

        case .failed(let failure):
            clearSlowTimer()
            stopElapsedTimer()
            earcons.play(.error)
            onStatusItemState?(.idle)
            showError(Self.copy(for: failure))
        }
    }

    private func handleOutcome(_ outcome: DictationOutcome) {
        switch outcome {
        case .inserted:
            earcons.play(.success)
            let words = coordinator.lastResult.map { $0.split(separator: " ").count }
            setPill(.success(words: words))
            dismissAfter(0.7)
        case .copiedToClipboard:
            earcons.play(.success)
            showNotice("Copied — press ⌘V to paste", for: 4.0, sound: nil)
        case .awaitingChip:
            showNotice("You switched apps — press ⌘V to paste", for: 5.0, sound: nil)
        case .heldForSecureField:
            showNotice("Can't dictate into a password field", for: 2.5, sound: nil)
        case .queuedForRetry:
            showNotice("You're offline — saved to History", for: 4.0, sound: nil)
        case .silent:
            showNotice("Didn't catch any speech", for: 2.0, sound: nil)
        }
    }

    // MARK: - Pill helpers

    private func setPill(_ state: PillState) {
        hud.model.state = state
        if case .processing = state {} else {
            hud.model.slow = false
        }
    }

    private func showNotice(_ message: String, for seconds: TimeInterval, sound: EarconPlayer.Earcon?) {
        if let sound {
            earcons.play(sound)
        }
        setPill(.notice(message))
        dismissAfter(seconds)
    }

    private func showError(_ message: String) {
        setPill(.error(message))
        dismissAfter(6.0)
    }

    private func dismissAfter(_ seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.setPill(.idleDot)
        }
    }

    // MARK: - Timers

    private func startElapsedTimer() {
        hud.model.elapsed = 0
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.sessionStartedAt else { return }
                self.hud.model.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func armSlowTimer() {
        slowTimer?.invalidate()
        slowTimer = Timer.scheduledTimer(withTimeInterval: TimeoutPolicy.slowStateUI, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hud.model.slow = true
            }
        }
    }

    private func clearSlowTimer() {
        slowTimer?.invalidate()
        slowTimer = nil
        hud.model.slow = false
    }

    // MARK: - Permissions & copy

    private func resolveMicPermission() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.permissions.info("microphone auth status: \(micStatus.rawValue) (3=authorized)")
        switch micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.permissions.info("microphone request resolved: \(granted)")
            }
        case .denied, .restricted:
            onStatusChange?("Microphone access is off — enable it in System Settings → Privacy → Microphone")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default:
            break
        }
    }

    private static func copy(for failure: DictationFailure) -> String {
        switch failure {
        case .network: return "Couldn't reach Gemini — saved to History"
        case .auth: return "API key isn't working — saved to History"
        case .quotaExhausted: return "Daily quota reached — saved to History"
        case .timeout: return "Timed out — saved to History"
        case .validation: return "Couldn't transcribe — saved to History"
        case .safetyBlocked: return "The API declined this one — saved to History"
        case .noAudio: return "Mic didn't start in time — try again"
        case .audio: return "Mic didn't start — try again"
        case .storage: return "Disk problem — couldn't save the audio"
        }
    }
}
