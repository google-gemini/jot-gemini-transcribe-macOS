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

    public struct Session {
        public let id: UUID
        public let folder: URL
        public let startedAt: Date
        public var context: DictationContext
        public var meta: SessionMeta
    }

    private var session: Session?
    private var capture: AudioCapturing?

    private let audioFactory: @MainActor () -> AudioCapturing
    private let transcription: TranscriptionServicing
    private let insertion: TextInserting
    private let contextProvider: @MainActor () -> DictationContext

    public init(
        audioFactory: @escaping @MainActor () -> AudioCapturing,
        transcription: TranscriptionServicing,
        insertion: TextInserting,
        contextProvider: @escaping @MainActor () -> DictationContext = { DictationContext() }
    ) {
        self.audioFactory = audioFactory
        self.transcription = transcription
        self.insertion = insertion
        self.contextProvider = contextProvider
    }

    // MARK: - Hotkey entry point

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
            cancelSession(hint: "Hold to talk — double-tap to lock")
        case .abortAccidental:
            cancelSession(hint: nil)
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
        let startedAt = Date()
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
            capture.onDeviceChange = { message in
                Log.audio.info("device change surfaced: \(message, privacy: .public)")
            }
            // Prewarm-on-keydown: engine starts before grammar classification so
            // t=0 audio is never lost (VoiceInk #687 is the canonical race).
            try capture.start(writingTo: FileLayout.audioCAF(in: folder))
            apply(.engineStarted)
        } catch {
            Log.audio.error("audio engine failed to start: \(error)")
            updateMeta { $0.status = .failed; $0.errorCode = "audio_start" }
            apply(.engineFailed)
        }
    }

    private func finalizeSession() {
        guard let session else { return }
        apply(.finalize)
        let result = capture?.stop() ?? AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        capture = nil
        micLevel = 0

        guard result.framesWritten > 0 else {
            updateMeta { $0.status = .failed; $0.errorCode = "no_audio" }
            apply(.noAudioCaptured)
            return
        }
        updateMeta {
            $0.status = .recorded
            $0.audioDurationSeconds = result.durationSeconds
            $0.gapMarkers = result.gapMarkers
        }
        apply(.audioFinalized)

        let sessionID = session.id
        let finalizeStartedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.transcription.transcribe(
                    audioURL: FileLayout.audioCAF(in: session.folder),
                    durationSeconds: result.durationSeconds,
                    context: session.context
                )
                await self.completeTranscription(sessionID: sessionID, outcome: outcome, startedAt: finalizeStartedAt)
            } catch {
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
        let failure: DictationFailure
        let code: String
        switch error as? TranscriptionError {
        case .offline, .network: failure = .network; code = "network"
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
        guard state != .idle || session != nil else {
            coachingHint = hint
            return
        }
        _ = capture?.stop()
        capture = nil
        micLevel = 0
        updateMeta { $0.status = .cancelled }
        apply(.cancel)
        coachingHint = hint
        session = nil
    }

    // MARK: - Machine plumbing

    private func apply(_ event: DictationEvent) {
        guard let next = DictationStateMachine.transition(state, on: event) else {
            Log.session.debug("ignored event \(String(describing: event), privacy: .public) in \(String(describing: self.state), privacy: .public)")
            return
        }
        state = next
        Log.session.info("state → \(String(describing: next), privacy: .public)")
    }

    private func updateMeta(_ mutate: (inout SessionMeta) -> Void) {
        guard var session else { return }
        mutate(&session.meta)
        session.meta.write(to: session.folder)
        self.session = session
    }
}
