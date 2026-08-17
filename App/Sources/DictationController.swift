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
    private let transcriptionService: GeminiTranscriptionService
    private let historyStore: HistoryStore?
    private var recoveryScanner: RecoveryScanner?
    private var retryQueue: RetryQueue?
    private var mainWindow: MainWindowController?
    private var onboardingWindow: OnboardingWindowController?
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
        let service = GeminiTranscriptionService(client: client)
        transcriptionService = service
        historyStore = try? HistoryStore.standard()
        coordinator = DictationCoordinator(
            audioFactory: { AudioCaptureEngine() },
            transcription: service,
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

    private var needsOnboarding: Bool {
        KeychainStore.loadAPIKey() == nil
            || !AXIsProcessTrusted()
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
    }

    func start() {
        applyHotkeySettings()
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
        NotificationCenter.default.addObserver(forName: .pillDotTapped, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.startHandsFree()
            }
        }

        bind()
        startHistoryServices()

        if needsOnboarding {
            presentOnboarding()
        } else {
            activateEngine()
        }

        if FnUsageAdvisor.karabinerIsPresent() {
            Log.hotkey.warning("Karabiner-Elements detected — fn capture may conflict")
        }
    }

    private func activateEngine() {
        if engine.start() {
            onStatusChange?("Ready — hold \(SettingsStore().hotkeyKey.displayName) to dictate")
            hud.show()
        } else {
            onStatusChange?("Grant Accessibility to enable the dictation key")
        }
    }

    private func presentOnboarding() {
        guard onboardingWindow == nil else {
            onboardingWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = OnboardingWindowController { [weak self] in
            guard let self else { return }
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            self.activateEngine()
        }
        onboardingWindow = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyHotkeySettings() {
        let settings = SettingsStore()
        engine.setKey(settings.hotkeyKey)
        engine.setDoubleTapLockEnabled(settings.doubleTapLockEnabled)
    }

    // MARK: - History, recovery, retry queue

    private func startHistoryServices() {
        guard let historyStore else {
            Log.history.error("HistoryStore unavailable — history features disabled")
            return
        }
        coordinator.onSessionUpdate = { meta, folder in
            historyStore.upsert(meta: meta, folder: folder)
        }

        let scanner = RecoveryScanner(store: historyStore, transcription: transcriptionService)
        scanner.onRecovered = { [weak self] message in
            self?.showNotice(message, for: 4.0, sound: .success)
        }
        recoveryScanner = scanner

        let queue = RetryQueue(store: historyStore, transcription: transcriptionService)
        queue.onDrained = { [weak self] count in
            let message = count == 1
                ? "Your queued dictation is ready — it's in History"
                : "\(count) queued dictations are ready — they're in History"
            self?.showNotice(message, for: 4.0, sound: .success)
        }
        retryQueue = queue

        Task {
            await scanner.scanAndRecover()
            queue.start()
            RetentionPolicy().purgeExpiredAudio()
        }
    }

    func openHistory() {
        openMainWindow(section: .history)
    }

    func openSettings() {
        openMainWindow(section: .general)
    }

    private func openMainWindow(section: MainSection) {
        if mainWindow == nil {
            mainWindow = MainWindowController(
                store: historyStore,
                onRetry: { [weak self] record in
                    Task { @MainActor [weak self] in
                        _ = await self?.retryQueue?.retrySingle(record)
                    }
                },
                onHotkeyConfigChanged: { [weak self] in self?.applyHotkeySettings() },
                onDeleteAllHistory: { [weak self] in
                    self?.historyStore?.deleteAll(removeFolders: true)
                }
            )
        }
        mainWindow?.show(section: section)
    }

    /// UI-initiated hands-free session (idle-dot click, menu item). Note: the
    /// hotkey engine's grammar stays idle for these, so ending the session is via
    /// the pill's stop button or a press-and-release of the dictation key.
    func startHandsFree() {
        coordinator.handle(.begin)
        coordinator.handle(.lockIn)
    }

    func pasteLastTranscript() {
        guard let text = coordinator.lastResult else { return }
        Task { @MainActor in
            let app = NSWorkspace.shared.frontmostApplication
            let context = DictationContext(
                targetAppBundleID: app?.bundleIdentifier,
                targetAppName: app?.localizedName,
                targetPID: app?.processIdentifier
            )
            _ = await InsertionCoordinator().insert(text, context: context)
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

    // MARK: - Copy

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
