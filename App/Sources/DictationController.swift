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
        // Intents flow through one AsyncStream consumed sequentially — independent
        // Task hops have no ordering guarantee under load (audit L35).
        let (intentStream, continuation) = AsyncStream.makeStream(of: HotkeyIntent.self)
        engine.onIntent = { intent in
            continuation.yield(intent)
        }
        Task { @MainActor [weak self] in
            for await intent in intentStream {
                guard let self else { break }
                self.coordinator.handle(intent)
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
        // Settings must take effect the moment they're flipped — not on the next
        // unrelated pill transition (dogfood: resting-dot toggle "didn't work").
        NotificationCenter.default.addObserver(forName: .gtSettingDidChange, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                self?.applySettingChange(key: note.object as? String)
            }
        }
        // Auto-degrade must never be silent: the user's next dictations arrive
        // verbatim, and they deserve to know why and where to turn it back on.
        NotificationCenter.default.addObserver(forName: .gtSmartFormattingAutoDegraded, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Deferred: this fires MID-SESSION (inside the cleanup call) and a
                // direct notice would be stomped by the session's own transitions.
                self?.showBackgroundNotice("Smart formatting paused — cleanup kept misfiring. Re-enable in Settings → Dictation.", for: 5.0, sound: nil)
            }
        }

        bind()
        startHistoryServices()

        // F15: finalize gracefully when the Mac sleeps mid-recording (audit L1).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .recording = self.coordinator.state {
                    Log.session.info("system sleeping — finalizing active dictation")
                    self.coordinator.handle(.finalize)
                }
            }
        }

        // Retention shouldn't depend on relaunches (audit L11): purge every 6h.
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task.detached(priority: .utility) {
                RetentionPolicy().purgeExpiredAudio()
            }
        }

        if needsOnboarding {
            presentOnboarding()
        } else {
            activateEngine()
        }

        if FnUsageAdvisor.karabinerIsPresent() {
            Log.hotkey.warning("Karabiner-Elements detected — fn capture may conflict")
        }
    }

    /// True once engine.start() has succeeded — status-line rewrites must never
    /// paint "Ready" over an unstarted engine's attention message.
    private var engineActive = false

    private func activateEngine() {
        if engine.start() {
            engineActive = true
            if KeychainStore.loadAPIKey() == nil {
                // New-user path: dictation can't work yet — say exactly where to go.
                onStatusChange?("Add your Gemini API key in Settings → Advanced")
                onStatusItemState?(.attention)
            } else {
                onStatusChange?("Ready — hold \(SettingsStore().hotkeyKey.displayName) to dictate")
                // Clear a lingering attention icon (auth failure, missing key).
                onStatusItemState?(.idle)
            }
            hud.show()
        } else {
            onStatusChange?("Grant Accessibility to enable the dictation key")
            onStatusItemState?(.attention)
        }
    }

    private func presentOnboarding() {
        guard onboardingWindow == nil else {
            onboardingWindow?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = OnboardingWindowController(
            onFinished: { [weak self] in
                guard let self else { return }
                self.onboardingWindow?.close()
            },
            onClosed: { [weak self] in
                guard let self else { return }
                self.onboardingWindow = nil
                if !self.needsOnboarding {
                    self.activateEngine()
                }
            }
        )
        onboardingWindow = window
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyHotkeySettings() {
        let settings = SettingsStore()
        engine.setKey(settings.hotkeyKey)
        engine.setDoubleTapLockEnabled(settings.doubleTapLockEnabled)
    }

    private func applySettingChange(key: String?) {
        switch key {
        case "showIdleIndicator":
            // Re-apply only when resting — setPill maps idleDot ⇄ hidden by the
            // setting; never touch an active session's pill.
            if hud.model.state == .idleDot || hud.model.state == .hidden {
                setPill(.idleDot)
            }
        case "hotkeyKey", "doubleTapLock":
            applyHotkeySettings()
            // The menu-bar status line names the key — keep it truthful, but
            // never overwrite an attention message ("Grant Accessibility…").
            if engineActive, KeychainStore.loadAPIKey() != nil {
                onStatusChange?("Ready — hold \(SettingsStore().hotkeyKey.displayName) to dictate")
            }
        case "apiKey":
            if KeychainStore.loadAPIKey() != nil {
                // Covers the "I'll add it later" onboarding path, where the
                // engine was never started: a key arriving in Settings must
                // bring the whole app to life, not just flip a badge.
                // engine.start() is reentrant; hud.show() is idempotent.
                activateEngine()
            } else {
                onStatusChange?("Add your Gemini API key in Settings → Advanced")
                onStatusItemState?(.attention)
            }
        default:
            break
        }
    }

    // MARK: - History, recovery, retry queue

    private func startHistoryServices() {
        guard let historyStore else {
            Log.history.error("HistoryStore unavailable — history features disabled")
            return
        }
        coordinator.onSessionDiscard = { id in
            historyStore.delete(id: id.uuidString, removeFolder: false)
        }
        coordinator.onSessionUpdate = { meta, folder in
            historyStore.upsert(meta: meta, folder: folder)
            // "Never keep audio": purge the moment a transcript exists (audit #2).
            if SettingsStore().audioRetentionDays < 0, meta.rawTranscript != nil || meta.status == .silent {
                for audio in [FileLayout.audioCAF(in: folder), FileLayout.audioFLAC(in: folder)] {
                    try? FileManager.default.removeItem(at: audio)
                }
            }
        }

        let scanner = RecoveryScanner(store: historyStore, transcription: transcriptionService)
        scanner.onRecovered = { [weak self] message in
            self?.showBackgroundNotice(message, for: 4.0, sound: .success)
        }
        recoveryScanner = scanner

        let queue = RetryQueue(store: historyStore, transcription: transcriptionService)
        queue.onDrained = { [weak self] count in
            let message = count == 1
                ? "Your queued dictation is ready — it's in History"
                : "\(count) queued dictations are ready — they're in History"
            self?.showBackgroundNotice(message, for: 4.0, sound: .success)
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

    func openSettings(section: String? = nil) {
        openMainWindow(section: section.flatMap(MainSection.init(rawValue:)) ?? .general)
    }

    func openDictionary() {
        openMainWindow(section: .dictionary)
    }

    /// transcribe://onboarding — re-run setup on demand (also drives headless UI checks).
    func presentOnboardingManually() {
        presentOnboarding()
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
                onDeleteAllHistory: { [weak self] in
                    guard let self else { return }
                    if let store = self.historyStore {
                        store.deleteAll(
                            removeFolders: true,
                            sparing: self.coordinator.activeSessionFolder
                        )
                    } else {
                        // No DB handle (quarantined at launch) must not turn the
                        // destructive button into a silent no-op — the folders
                        // are the actual data; sweep them directly.
                        let folders = (try? FileManager.default.contentsOfDirectory(
                            at: FileLayout.recordingsRoot, includingPropertiesForKeys: nil
                        )) ?? []
                        let active = self.coordinator.activeSessionFolder?.standardizedFileURL
                        for folder in folders where folder.hasDirectoryPath && folder.standardizedFileURL != active {
                            try? FileManager.default.removeItem(at: folder)
                        }
                    }
                    // Wiping history also forgets the paste-last buffer.
                    self.coordinator.clearLastResult()
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

        // Esc must reach us even when the grammar is idle: in-flight transcription
        // and UI-started hands-free are "externally active" (audit L8/L13).
        // NOT .inserting: cancel is rejected there by design (the text exists),
        // so consuming Esc would just eat the user's keystroke for ~1s.
        switch state {
        case .finalizing, .transcribing, .recording:
            engine.setExternalSessionActive(true)
        default:
            engine.setExternalSessionActive(false)
        }

        // Background notices deferred during a live session flush once it ends.
        if case .idle = state { flushPendingNotice() }
        if state.isTerminal { flushPendingNotice() }

        switch state {
        case .idle:
            setPill(.idleDot)
            onStatusItemState?(.idle)

        case .warming:
            sessionStartedAt = Date()
            earcons.play(.start)
            hud.repositionToActiveScreen() // follow the dictation display (audit L14)
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
            // Key/permission problems persist beyond the toast — the menu bar
            // icon carries the attention state until resolved (audit L12).
            onStatusItemState?(failure == .auth ? .attention : .idle)
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
        // "Only while dictating" preference: the resting dot becomes nothing.
        if case .idleDot = state, !SettingsStore().showIdleIndicator {
            hud.model.state = .hidden
        } else {
            hud.model.state = state
        }
        if case .processing = state {} else {
            hud.model.slow = false
        }
    }

    /// Notices about BACKGROUND events (retry drain, recovery, auto-degrade)
    /// must never hijack a live session's pill — they wait for it to end.
    /// Session-critical notices (cap warning, device change) still interrupt.
    private var pendingNotice: (message: String, seconds: TimeInterval, sound: EarconPlayer.Earcon?)?

    private func showBackgroundNotice(_ message: String, for seconds: TimeInterval, sound: EarconPlayer.Earcon?) {
        switch coordinator.state {
        case .idle, .done, .cancelled, .failed:
            showNotice(message, for: seconds, sound: sound)
        default:
            pendingNotice = (message, seconds, sound)
        }
    }

    private func flushPendingNotice() {
        guard let notice = pendingNotice else { return }
        pendingNotice = nil
        // Give the terminal pill (success check / error chip) its moment first.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self else { return }
            switch self.coordinator.state {
            case .idle, .done, .cancelled, .failed:
                self.showNotice(notice.message, for: notice.seconds, sound: notice.sound)
            default:
                // A new session started — re-queue for its end.
                self.pendingNotice = self.pendingNotice ?? notice
            }
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
            guard !Task.isCancelled, let self else { return }
            // Re-derive from coordinator state — a hardcoded .idleDot after the
            // 9-min cap warning stranded a HOT MIC behind the resting dot
            // (production pass 2, P0). Terminal/idle states still land on the dot.
            self.setPill(Self.restingPill(for: self.coordinator.state))
        }
    }

    private static func restingPill(for state: DictationState) -> PillState {
        switch state {
        case .warming: return .listening(locked: false)
        case .recording(let locked): return .listening(locked: locked)
        case .finalizing, .transcribing, .inserting: return .processing
        default: return .idleDot
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
        case .auth:
            return KeychainStore.loadAPIKey() == nil
                ? "Add your Gemini API key in Settings — recording saved to History"
                : "API key isn't working — saved to History"
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
