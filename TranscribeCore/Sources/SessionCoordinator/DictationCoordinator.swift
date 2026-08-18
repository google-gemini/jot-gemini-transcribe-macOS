import Foundation

/// The brain: translates hotkey intents into session lifecycle via the pure
/// DictationStateMachine, drives audio → transcription → insertion, and owns the
/// per-session folder + meta.json writes.
///
/// M2 scope: one session at a time (overlapping in-flight sessions arrive with M3's
/// async transcription). All state hops through the main actor.
@MainActor
public final class DictationCoordinator: ObservableObject {
    // Observable surface for the HUD / status item.
    @Published public private(set) var state: DictationState = .idle
    @Published public private(set) var micLevel: Float = 0
    @Published public private(set) var lastResult: String?
    @Published public private(set) var coachingHint: String?

    /// "Delete All History" should also forget the paste-last buffer — a user
    /// wiping their words expects them gone from everywhere we hold them.
    public func clearLastResult() {
        lastResult = nil
    }

    public struct Session {
        public let id: UUID
        public let folder: URL
        public let startedAt: Date
        public var context: DictationContext
        public var meta: SessionMeta
        /// Peak mic level from capture — silence vs dropped-transcript evidence.
        public var peakLevel: Float = 1.0
    }

    /// Below this metered peak the user simply didn't speak (F9b). Scale matches
    /// AudioCaptureEngine's onLevel; whisper-quiet speech peaks well above it.
    static let silencePeakThreshold: Float = 0.06
    /// Clips shorter than this can't contain a word — never sent to the API
    /// (dogfood: a 0.19s blip got uploaded, errored, and showed as Failed).
    static let minimumSendableDuration: Double = 0.4
    /// Zero frames on a hold shorter than this is an accidental blip, not an
    /// engine failure — the first buffer simply hadn't arrived yet.
    static let blipHoldThreshold: TimeInterval = 0.8
    /// F20: soft warning at 9:00, hard stop + transcribe at 10:00.
    static let recordingWarnSeconds: TimeInterval = 540
    static let recordingCapSeconds: TimeInterval = 600

    private var capWarnTask: Task<Void, Never>?
    private var capStopTask: Task<Void, Never>?
    /// The in-flight transcription task — cancelled when the user cancels the
    /// session (audit L8: Esc previously left the network work running).
    private var inFlightTask: Task<Void, Never>?

    /// Folder of the live session, if any — Delete All must not sweep it (audit L7).
    public var activeSessionFolder: URL? { session?.folder }

    private var session: Session?
    private var capture: AudioCapturing?

    /// Fired after every meta.json write — the app mirrors sessions into HistoryStore.
    public var onSessionUpdate: ((SessionMeta, URL) -> Void)?
    /// Fired when a session's artifacts were discarded entirely (blips, no-speech,
    /// short cancels) — the app removes its History row. Disk mirrors the UI:
    /// what History doesn't show, we don't store.
    public var onSessionDiscard: ((UUID) -> Void)?

    /// Cancelled recordings at least this long stay recoverable in History —
    /// an accidental Esc after minutes of dictation must not destroy the words.
    static let cancelKeepThreshold: Double = 10

    private let audioFactory: @MainActor () -> AudioCapturing
    private let transcription: TranscriptionServicing
    private let insertion: TextInserting
    private let contextProvider: @MainActor () -> DictationContext
    /// Injectable clock so hold-duration classification is testable.
    private let now: () -> Date

    public init(
        audioFactory: @escaping @MainActor () -> AudioCapturing,
        transcription: TranscriptionServicing,
        insertion: TextInserting,
        contextProvider: @escaping @MainActor () -> DictationContext = { DictationContext() },
        now: @escaping () -> Date = Date.init
    ) {
        self.audioFactory = audioFactory
        self.transcription = transcription
        self.insertion = insertion
        self.contextProvider = contextProvider
        self.now = now
    }

    // MARK: - Hotkey entry point

    static let coachTip = "Hold to talk · tap Space while holding for hands-free"

    public func handle(_ intent: HotkeyIntent) {
        switch intent {
        case .begin:
            beginSession()
        case .lockIn:
            apply(.lockIn)
        case .finalize:
            finalizeSession()
        case .cancel:
            cancelSession(hint: nil)
        case .shortTapHint:
            handleShortTap()
        case .abortAccidental:
            handleAccidentalChord()
        }
    }

    /// An accidental chord is context-sensitive for the same reason as a short
    /// tap (audit #1 — a chord must NEVER destroy someone else's session):
    ///  - hands-free recording → the fn press was a stop gesture on a UI-started
    ///    session (grammar-locked sessions finalize on key-down and never reach
    ///    here) — finalize, don't destroy the words
    ///  - the chord's own young session (warming / unlocked) → silent cancel
    ///    (the original accidental-chord guard, unchanged)
    ///  - a session in flight → ignored; the transcript is sacred
    private func handleAccidentalChord() {
        switch state {
        case .recording(locked: true):
            finalizeSession()
        case .warming, .recording:
            cancelSession(hint: nil)
        case .finalizing, .transcribing, .inserting:
            Log.session.info("accidental chord ignored — session in flight")
        default:
            break
        }
    }

    /// A quick tap is context-sensitive (audit finding #1 — a tap must NEVER
    /// destroy someone else's session):
    ///  - hands-free recording → the tap STOPS it (finalize)
    ///  - the tap's own young session (warming / unlocked recording) → cancel + coach
    ///  - a session in flight (finalizing/transcribing/inserting) → ignored;
    ///    the transcript is sacred
    ///  - idle/terminal → just the coaching hint
    private func handleShortTap() {
        switch state {
        case .recording(locked: true):
            finalizeSession()
        case .warming, .recording:
            cancelSession(hint: Self.coachTip)
        case .finalizing, .transcribing, .inserting:
            Log.session.info("short tap ignored — session in flight")
        default:
            coachingHint = Self.coachTip
        }
    }

    // MARK: - Session lifecycle

    private func beginSession() {
        guard state == .idle || state.isTerminal else {
            Log.session.info("begin ignored: session already active (\(String(describing: self.state), privacy: .public))")
            return
        }
        // F18: never record over a password field.
        if SecureInput.isActive {
            coachingHint = "Can't dictate into a password field"
            Log.session.info("begin refused: secure input active")
            return
        }
        state = .idle
        coachingHint = nil
        apply(.hotkeyBegin)

        let id = UUID()
        let startedAt = now()
        do {
            let folder = try FileLayout.makeSessionFolder(id: id, now: startedAt)
            var meta = SessionMeta(id: id, startedAt: startedAt, status: .recording)
            let context = contextProvider()
            meta.targetAppBundleID = context.targetAppBundleID
            meta.targetAppName = context.targetAppName
            meta.write(to: folder)
            session = Session(id: id, folder: folder, startedAt: startedAt, context: context, meta: meta)

            let capture = audioFactory()
            self.capture = capture
            capture.onLevel = { [weak self] level in
                Task { @MainActor [weak self] in self?.micLevel = level }
            }
            capture.onDeviceChange = { [weak self] message in
                Log.audio.info("device change surfaced: \(message, privacy: .public)")
                // Mid-recording mic switch must be VISIBLE — an AirPods
                // auto-connect changes what's being recorded (production pass 2).
                Task { @MainActor [weak self] in
                    if case .recording = self?.state {
                        self?.coachingHint = message
                    }
                }
            }
            capture.onWriteFailure = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleWriteFailure()
                }
            }
            capture.onEngineDied = { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handleEngineDeath(message)
                }
            }
            // Prewarm-on-keydown: engine starts before grammar classification so
            // t=0 audio is never lost (VoiceInk #687 is the canonical race).
            try capture.start(writingTo: FileLayout.audioCAF(in: folder))
            apply(.engineStarted)
            startCapTimers()
        } catch {
            Log.audio.error("audio engine failed to start: \(error)")
            updateMeta { $0.status = .failed; $0.errorCode = "audio_start" }
            apply(.engineFailed)
            // Release the failed engine + its open CAF handle (audit L19).
            _ = capture?.stop()
            capture = nil
            self.session = nil
        }
    }

    // MARK: - Recording cap (F20) & disk failure (F22)

    private func startCapTimers() {
        capWarnTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.recordingWarnSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                if case .recording = self?.state {
                    self?.coachingHint = "One minute left — 10-minute limit"
                }
            }
        }
        capStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.recordingCapSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, case .recording = self.state else { return }
                Log.session.info("recording cap reached — finalizing")
                self.finalizeSession()
            }
        }
    }

    private func stopCapTimers() {
        capWarnTask?.cancel(); capWarnTask = nil
        capStopTask?.cancel(); capStopTask = nil
    }

    private func handleWriteFailure() {
        guard case .recording = state else { return }
        Log.audio.error("sustained CAF write failures — finalizing with what we have (F22)")
        updateMeta { $0.errorCode = "disk_write" }
        finalizeSession()
    }

    /// Engine died mid-recording and could not be revived: a pill that keeps
    /// "listening" while nothing records loses every word after the seam.
    /// Finalize with the partial audio — same shape as handleWriteFailure.
    private func handleEngineDeath(_ message: String) {
        guard case .recording = state else { return }
        Log.audio.error("audio engine died mid-recording (\(message, privacy: .public)) — finalizing with what we have")
        updateMeta { $0.errorCode = "engine_died" }
        coachingHint = "\(message) — dictating what was captured"
        finalizeSession()
    }

    private func finalizeSession() {
        guard var session else { return }
        // The machine decides first; side effects only on an ACCEPTED finalize
        // (same pattern as cancelSession, audit #10). A second stop while a
        // session is in flight must not stop capture or clobber meta.
        guard apply(.finalize) else { return }
        stopCapTimers()
        let result = capture?.stop() ?? AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        capture = nil
        micLevel = 0

        let heldFor = now().timeIntervalSince(session.startedAt)
        guard result.framesWritten > 0 else {
            if heldFor < Self.blipHoldThreshold {
                // Accidental blip: released before the first buffer landed. Not an
                // error — and not worth storing (pill feedback only).
                apply(.silenceOnly)
                discardSessionArtifacts()
                self.session = nil
                return
            }
            updateMeta { $0.status = .failed; $0.errorCode = "no_audio" }
            apply(.noAudioCaptured)
            return
        }
        session.peakLevel = result.peakLevel
        self.session = session
        updateMeta {
            $0.status = .recorded
            $0.audioDurationSeconds = result.durationSeconds
            $0.gapMarkers = result.gapMarkers
        }

        // Micro-clips can't contain a word — classify locally, never upload
        // (the API errors on them, which used to surface as Failed).
        guard result.durationSeconds >= Self.minimumSendableDuration else {
            apply(.silenceOnly)
            discardSessionArtifacts()
            self.session = nil
            return
        }
        apply(.audioFinalized)

        let sessionID = session.id
        let finalizeStartedAt = Date()
        inFlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.transcription.transcribe(
                    audioURL: FileLayout.audioCAF(in: session.folder),
                    durationSeconds: result.durationSeconds,
                    context: session.context
                )
                guard !Task.isCancelled else { return }
                await self.completeTranscription(sessionID: sessionID, outcome: outcome, startedAt: finalizeStartedAt)
            } catch {
                guard !Task.isCancelled else { return }
                await self.failTranscription(sessionID: sessionID, error: error)
            }
        }
    }

    private func completeTranscription(sessionID: UUID, outcome: TranscriptionResult, startedAt: Date) async {
        guard session?.id == sessionID else { return } // stale completion
        updateMeta {
            $0.rawTranscript = outcome.rawTranscript
            $0.cleanedTranscript = outcome.cleanedTranscript
            $0.modelID = outcome.modelID
            $0.status = .transcribing
        }
        apply(.transcriptReady)

        let insertionOutcome = await insertion.insert(outcome.cleanedTranscript, context: session?.context ?? DictationContext())
        let pipelineSeconds = Date().timeIntervalSince(startedAt)
        switch insertionOutcome {
        case .inserted:
            updateMeta { $0.status = .inserted; $0.pipelineSeconds = pipelineSeconds }
            apply(.inserted)
        case .frontmostChanged:
            updateMeta { $0.status = .awaitingChip; $0.pipelineSeconds = pipelineSeconds }
            apply(.frontmostChangedAwaitingChip)
        case .fellBackToClipboard:
            updateMeta { $0.status = .copiedToClipboard; $0.pipelineSeconds = pipelineSeconds }
            apply(.insertionFellBackToClipboard)
        case .blockedSecureField:
            updateMeta { $0.status = .heldSecure; $0.pipelineSeconds = pipelineSeconds }
            apply(.insertionBlockedSecure)
        }
        lastResult = outcome.cleanedTranscript
        session = nil
    }

    private func failTranscription(sessionID: UUID, error: Error) async {
        guard session?.id == sessionID else { return }
        // Empty transcript: silence is judged by AUDIO ENERGY, not duration —
        // a long quiet hold is "no speech", never "Failed" (F9b; dogfood bug).
        // Speech energy present but no transcript = real failure, retryable (F9a).
        if case .some(.emptyTranscript) = error as? TranscriptionError {
            let peak = session?.peakLevel ?? 1.0
            let duration = session?.meta.audioDurationSeconds ?? 0
            // Energy decides; the duration escape hatch only covers true blips —
            // a LOUD 1s "Hi!" with a dropped transcript is a real failure (F9a).
            if peak < Self.silencePeakThreshold || duration < 0.6 {
                apply(.silenceOnly)
                discardSessionArtifacts()
                session = nil
                return
            }
        }
        // Offline is not a failure — the audio queues and drains on reconnect (F1).
        if case .some(.offline) = error as? TranscriptionError {
            updateMeta { $0.status = .queuedForRetry; $0.errorCode = "offline" }
            apply(.queuedForRetry)
            session = nil
            return
        }
        let failure: DictationFailure
        let code: String
        switch error as? TranscriptionError {
        case .offline: failure = .network; code = "offline" // handled above
        case .badRequest: failure = .validation; code = "bad_request"
        case .network: failure = .network; code = "network"
        case .auth: failure = .auth; code = "auth"
        case .rateLimitedDaily: failure = .quotaExhausted; code = "quota"
        case .timeout: failure = .timeout; code = "timeout"
        case .emptyTranscript: failure = .validation; code = "empty"
        case .safetyBlocked: failure = .safetyBlocked; code = "safety"
        case nil: failure = .network; code = "unknown"
        }
        updateMeta { $0.status = .failed; $0.errorCode = code }
        apply(.transcriptFailed(failure))
        session = nil
    }

    private func cancelSession(hint: String?) {
        // The machine decides first; side effects only on an ACCEPTED cancel
        // (audit finding #10 — a rejected cancel must not corrupt meta/session).
        guard apply(.cancel) else {
            coachingHint = hint
            return
        }
        inFlightTask?.cancel() // stop the network work too (audit L8)
        inFlightTask = nil
        let result = capture?.stop()
        capture = nil
        micLevel = 0
        stopCapTimers()

        // Post-finalize cancels have no live capture — fall back to the duration
        // finalizeSession already persisted, or Esc-during-transcription reads 0
        // and destroys a recording of ANY length (production pass 2, P0).
        let duration = result?.durationSeconds ?? session?.meta.audioDurationSeconds ?? 0
        let hasTranscript = session?.meta.rawTranscript != nil
        if hasTranscript || duration >= Self.cancelKeepThreshold {
            // Long cancels stay recoverable — History shows them with Retry.
            updateMeta {
                $0.status = .cancelled
                $0.audioDurationSeconds = $0.audioDurationSeconds ?? duration
            }
        } else {
            // Blips and short deliberate cancels leave no trace: the pill already
            // gave feedback in the moment; hidden audio is pure liability.
            discardSessionArtifacts()
        }
        coachingHint = hint
        session = nil
    }

    /// Removes the session folder and asks the app to drop its History row.
    private func discardSessionArtifacts() {
        guard let session else { return }
        try? FileManager.default.removeItem(at: session.folder)
        onSessionDiscard?(session.id)
    }

    // MARK: - Machine plumbing

    @discardableResult
    private func apply(_ event: DictationEvent) -> Bool {
        guard let next = DictationStateMachine.transition(state, on: event) else {
            Log.session.debug("ignored event \(String(describing: event), privacy: .public) in \(String(describing: self.state), privacy: .public)")
            return false
        }
        state = next
        Log.session.info("state → \(String(describing: next), privacy: .public)")
        return true
    }

    private func updateMeta(_ mutate: (inout SessionMeta) -> Void) {
        guard var session else { return }
        mutate(&session.meta)
        session.meta.write(to: session.folder)
        self.session = session
        onSessionUpdate?(session.meta, session.folder)
    }
}
