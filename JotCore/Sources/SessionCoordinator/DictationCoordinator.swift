// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
    /// Releasing the key a beat before the last word is finished is a NORMAL
    /// human gesture — the hand anticipates the mouth. When the user is still
    /// speaking at key-up, keep capturing until they actually stop.
    /// Costs nothing in the common case: already-quiet releases stop instantly.
    static let trailingSpeechThreshold: Float = 0.08
    /// Quiet this long ⇒ they finished the word.
    static let trailingQuietToStop: TimeInterval = 0.25
    /// Hard cap so a noisy room can never hold a session open.
    static let trailingCaptureCap: TimeInterval = 1.5
    /// How far above the measured room a level must sit to still read as speech.
    /// Only ever raises the bar from `trailingSpeechThreshold`, never lowers it.
    static let trailingFloorMarginDB: Double = 3
    /// The session must have shown at least this much separation between speech
    /// and room before we trust its energy readings enough to stop early. Below
    /// it we keep today's behaviour: run to the cap and never clip a word.
    static let trailingTrustSNR: Double = 12
    /// A mis-estimated floor must never make ordinary speech read as quiet.
    static let trailingRelativeCap: Float = 0.30
    /// Nothing rose this far above the room ⇒ nobody spoke, whatever the
    /// absolute peak says. Used to classify an empty transcript honestly.
    static let emptyTranscriptSNRThreshold: Double = 8
    /// A discard needs BOTH a quiet absolute peak and no separation from the
    /// room. This clause can only ever prevent a discard, never cause one.
    static let discardSNRThreshold: Double = 6

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

    /// `didSet` rather than a teardown call at each exit, because there are a
    /// dozen places that clear this — four early returns in `completeFinalize`
    /// alone (blip, zero frames, sub-0.4s, digital silence), plus cancel, error
    /// and warming paths. Every one of them must close the socket, and patching
    /// them individually is how one gets missed: the miss leaves an orphaned
    /// socket with an unclosed activity, still billing and still holding the
    /// actor, whose only remaining terminator is a timeout. A double-tap of the
    /// hotkey would leave two.
    private var session: Session? {
        didSet {
            guard oldValue?.id != session?.id else { return }
            partialPump?.cancel()
            partialPump = nil
            partialTranscript = ""
            correctedTranscript = ""
            correctionSegments = []
            lastInterim = ""
            guard let live = liveSession else { return }
            liveSession = nil
            Task { await live.abort() }
        }
    }
    /// The socket for the CURRENT session, if live mode is on and it opened.
    /// Never outlives `session` — see the `didSet` above.
    private var liveSession: LiveTranscribing?
    /// Latched at key-down, not read per-use: the user toggling the setting
    /// mid-dictation must not make one recording half-live.
    private var liveActiveForSession = false
    /// The words the model currently thinks it heard. Display only — never
    /// inserted, never stored. Cleared whenever a session ends so a fast second
    /// dictation cannot show the previous one's tail.
    @Published public private(set) var partialTranscript: String = ""
    private var partialPump: Task<Void, Never>?
    /// Set once, at the instant the model's finished answer replaces the running
    /// guess. The HUD sweeps on it. Distinct from `partialTranscript` because the
    /// sweep must fire on the CORRECTION, not on every revision — the interim
    /// text changes several times a second.
    @Published public private(set) var correctedTranscript: String = ""
    /// The edit smart transcription made, as kept/cut runs over what was said.
    /// Empty when nothing was removed or the two texts could not be aligned.
    @Published public private(set) var correctionSegments: [TranscriptDiff.Segment] = []
    /// The last interim hypothesis — close to literally what was said, and the
    /// left-hand side of the diff.
    private var lastInterim: String = ""
    private var capture: AudioCapturing?
    /// Most recent metered level — decides whether the user was mid-word when
    /// they released the key.
    private var latestLevel: Float = 0
    /// How loud the room is. Always measured, never in charge: what it feeds is
    /// gated on `noiseHandlingActive`, what it records is not.
    private var noiseFloor = NoiseFloorEstimator()
    /// Why the last session ended with no speech — the pill copy differs, nothing
    /// else does, so this rides alongside the outcome instead of widening the
    /// state machine for a string.
    public private(set) var lastSilenceReason: SilenceReason = .noSpeech
    /// The experiment's state, read ONCE at key-down. A toggle flipped while the
    /// pill is up must not change the rules the live recording is judged by.
    private var noiseHandlingActive = false
    /// Space-lock (or UI hands-free) that arrived while the engine was still
    /// coming up — applied on engineStarted, cleared when the session ends.
    private var pendingLockIn = false

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
    /// Injectable so the noise behaviours can be exercised both ways headlessly,
    /// without a UserDefaults round-trip in the test.
    private let noiseHandlingEnabled: @MainActor () -> Bool
    /// Injectable because the real check reads SYSTEM-WIDE state. Left un-injected,
    /// every begin-a-session test fails on any machine that happens to have secure
    /// input held — a stuck loginwindow after a lock screen, or Terminal's Secure
    /// Keyboard Entry — which is a coin flip for a contributor, not a bug in
    /// their change.
    private let secureInputActive: @MainActor () -> Bool
    /// Returns a live session, or nil when live mode is off or unavailable.
    /// Injected so the coordinator never needs to know about sockets or keys,
    /// and so tests can drive every live failure mode with no network.
    private let makeLiveSession: @MainActor () -> LiveTranscribing?

    public init(
        audioFactory: @escaping @MainActor () -> AudioCapturing,
        transcription: TranscriptionServicing,
        insertion: TextInserting,
        contextProvider: @escaping @MainActor () -> DictationContext = { DictationContext() },
        now: @escaping () -> Date = Date.init,
        noiseHandlingEnabled: @escaping @MainActor () -> Bool = { SettingsStore().experimentalNoiseHandling },
        secureInputActive: @escaping @MainActor () -> Bool = { SecureInput.isActive },
        makeLiveSession: @escaping @MainActor () -> LiveTranscribing? = { nil }
    ) {
        self.audioFactory = audioFactory
        self.transcription = transcription
        self.insertion = insertion
        self.contextProvider = contextProvider
        self.now = now
        self.noiseHandlingEnabled = noiseHandlingEnabled
        self.makeLiveSession = makeLiveSession
        self.secureInputActive = secureInputActive
    }

    // MARK: - Hotkey entry point

    static let coachTip = "Hold to talk · tap Space while holding for hands-free"

    /// Returns whether the intent was ACCEPTED — a refused .begin (secure field,
    /// session already active) must reach the hotkey grammar, or a Space-lock on
    /// the refused session strands it in .locked and eats the next dictation.
    @discardableResult
    public func handle(_ intent: HotkeyIntent) -> Bool {
        switch intent {
        case .begin:
            return beginSession()
        case .lockIn:
            // Engine start is deferred a tick (and Bluetooth mics take longer):
            // a lock arriving during warming must not be dropped — latch it and
            // apply the moment the engine reports started.
            if state == .warming {
                pendingLockIn = true
                return true
            }
            return apply(.lockIn)
        case .finalize:
            finalizeSession()
            return true
        case .cancel:
            cancelSession(hint: nil)
            return true
        case .shortTapHint:
            handleShortTap()
            return true
        case .abortAccidental:
            handleAccidentalChord()
            return true
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

    @discardableResult
    private func beginSession() -> Bool {
        guard state == .idle || state.isTerminal else {
            Log.session.info("begin ignored: session already active (\(String(describing: self.state), privacy: .public))")
            return false
        }
        // F18: never record over a secure input field.
        if secureInputActive() {
            // Name the app holding it and say what to do. The flag is SYSTEM-WIDE,
            // so the culprit is usually not the window the user is looking at —
            // "secure input is on" alone reads as "Jot is broken", especially
            // during onboarding where a stuck loginwindow flag is common.
            if let holder = SecureInput.holder() {
                coachingHint = "\(holder.name) has secure input on. \(SecureInput.advice(forHolder: holder.name))"
                Log.session.info("begin refused: secure input held by \(holder.name, privacy: .public) (pid \(holder.pid))")
            } else {
                coachingHint = "Can't dictate here — another app has secure input on"
                Log.session.info("begin refused: secure input active, holder unknown")
            }
            return false
        }
        state = .idle
        coachingHint = nil
        pendingLockIn = false // never inherit a stale latch from a dead session
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

            noiseFloor = NoiseFloorEstimator()
            noiseHandlingActive = noiseHandlingEnabled()

            let capture = audioFactory()
            self.capture = capture
            capture.onLevel = { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.ingestLevel(level, updatingMeter: true)
                }
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
            // Deferred ONE runloop turn: engine.start() blocks the main thread
            // (hundreds of ms on a Bluetooth mic renegotiating into headset
            // mode), and the pill cannot paint until this function returns —
            // the key press must be acknowledged instantly (dogfood).
            Task { @MainActor [weak self] in
                self?.startCaptureIfStillWarming(capture, sessionID: id, folder: folder)
            }
            return true
        } catch {
            Log.audio.error("session setup failed: \(error)")
            apply(.engineFailed(.audio))
            capture = nil
            discardSessionArtifacts()
            self.session = nil
            return false
        }
    }

    /// The deferred half of beginSession. The session may already be gone by
    /// the time this runs (Esc during warming, a blip release) — starting the
    /// mic for a dead session would record with no session to own the audio.
    private func startCaptureIfStillWarming(_ capture: AudioCapturing, sessionID: UUID, folder: URL) {
        guard session?.id == sessionID, self.capture === capture, state == .warming else {
            Log.audio.info("engine start skipped — session moved on before the mic came up")
            return
        }
        do {
            // Latched once, here: the user flipping the setting mid-dictation
            // must not produce a recording that is half streamed and half not.
            let live = makeLiveSession()
            liveSession = live
            liveActiveForSession = live != nil

            var sink: (@Sendable (Data) -> Void)?
            if let live {
                sink = { [weak live] pcm in live?.enqueue(pcm) }
                // Deliberately not awaited. Key-down must not wait on a socket —
                // a slow handshake would delay the mic, which is the one thing
                // that actually loses words. Audio accumulates in the ring
                // meanwhile, and a handshake that never lands simply means
                // finish() returns nil and the upload runs as it always has.
                partialPump?.cancel()
                partialPump = Task { [weak self] in
                    for await text in live.partials {
                        guard let self else { return }
                        // Late partials from a session the user already ended
                        // must not paint over the next one — same stale-session
                        // guard the transcript completion paths use.
                        guard self.session?.id == sessionID else { return }
                        self.lastInterim = text
                        self.partialTranscript = text
                    }
                }
                Task { [weak self] in
                    do { try await live.begin() } catch {
                        Log.transcription.info("live session did not open (\(error)) — this dictation uploads instead")
                        await MainActor.run { self?.liveActiveForSession = false }
                    }
                }
            }
            try capture.start(writingTo: FileLayout.audioCAF(in: folder), pcmSink: sink)
            apply(.engineStarted)
            if pendingLockIn {
                pendingLockIn = false
                apply(.lockIn)
            }
            startCapTimers()
        } catch {
            Log.audio.error("audio engine failed to start: \(error)")
            // Honest failure taxonomy: "Mic didn't start" is wrong advice on a
            // Mac with no input device at all. And zero frames were captured, so
            // there is NOTHING to store — a "Failed" History row with a dead-end
            // Retry would be a lie (blip/discard doctrine).
            let failure: DictationFailure =
                (error as? AudioCaptureEngine.CaptureError) == .noInputDevice ? .noMicrophone : .audio
            apply(.engineFailed(failure))
            // Release the failed engine + its open CAF handle (audit L19).
            if let failed = self.capture {
                Task.detached(priority: .utility) { _ = await failed.stop() }
            }
            self.capture = nil
            discardSessionArtifacts()
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

    /// The ONE place levels enter the coordinator.
    ///
    /// `captureTrailingSpeech` reassigns `capture.onLevel`, replacing the closure
    /// installed at session start. Both paths must feed the estimator or it
    /// starves in exactly the window that needs it most — the moment after key-up
    /// when we are deciding whether the user is still talking.
    private func ingestLevel(_ level: Float, updatingMeter: Bool) {
        if updatingMeter { micLevel = level }
        latestLevel = level
        noiseFloor.ingest(level: level)
    }

    /// The level below which the user has stopped talking.
    ///
    /// Absolute by default. With the experiment on it rises to sit just above a
    /// loud room — but only UPWARD from the absolute threshold, and only when the
    /// session has proved it can tell speech from the room at all. Without that
    /// separation the energy signal is not trustworthy, so we keep today's
    /// behaviour and pay the full cap rather than risk clipping a word.
    private func currentTrailingThreshold() -> Float {
        guard noiseHandlingActive,
              let floorDB = noiseFloor.floorDB,
              let snr = noiseFloor.measuredSNR,
              snr >= Self.trailingTrustSNR
        else { return Self.trailingSpeechThreshold }
        let targetDB = floorDB + Self.trailingFloorMarginDB
        let relative = AudioLevelCurve.level(fromRMS: Float(pow(10, targetDB / 20)))
        return min(Self.trailingRelativeCap, max(Self.trailingSpeechThreshold, relative))
    }

    private func finalizeSession() {
        guard session != nil else { return }
        // The machine decides first; side effects only on an ACCEPTED finalize
        // (same pattern as cancelSession, audit #10). A second stop while a
        // session is in flight must not stop capture or clobber meta.
        guard apply(.finalize) else { return }
        stopCapTimers()
        // Hand the engine off and release it immediately: stop() now drains the
        // HAL's in-flight buffer (~50ms mean of real speech) and tears the graph
        // down — tens to hundreds of ms that must not freeze the main actor. The
        // pill is already showing .finalizing, so the wait is visually covered.
        let engine = capture
        capture = nil
        let wasSpeaking = latestLevel >= currentTrailingThreshold()
        micLevel = 0
        Task { @MainActor [weak self] in
            if wasSpeaking, let engine {
                await self?.captureTrailingSpeech(from: engine)
            }
            let result = await engine?.stop() ?? AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
            self?.completeFinalize(result: result)
        }
    }

    /// Keep the mic open past key-up until the user actually stops talking.
    /// Returns as soon as they're quiet — capped so it can never hang.
    private func captureTrailingSpeech(from engine: AudioCapturing) async {
        // Real elapsed time, not the injectable session clock: this is about how
        // long actual audio keeps arriving.
        let start = DispatchTime.now()
        func elapsed(since mark: DispatchTime) -> TimeInterval {
            Double(DispatchTime.now().uptimeNanoseconds - mark.uptimeNanoseconds) / 1_000_000_000
        }
        var quietSince: DispatchTime?
        // The engine keeps reporting levels after key-up; watch them directly.
        engine.onLevel = { [weak self] level in
            // updatingMeter: false — the pill already shows .finalizing; this is
            // about hearing whether they are still talking, not drawing bars.
            Task { @MainActor [weak self] in self?.ingestLevel(level, updatingMeter: false) }
        }
        while elapsed(since: start) < Self.trailingCaptureCap {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if latestLevel < currentTrailingThreshold() {
                let since = quietSince ?? DispatchTime.now()
                quietSince = since
                if elapsed(since: since) >= Self.trailingQuietToStop { break }
            } else {
                quietSince = nil
            }
        }
        let carried = elapsed(since: start)
        Log.audio.info("carried capture \(carried * 1000, format: .fixed(precision: 0))ms past key-up — you were still talking")
    }

    private func completeFinalize(result: AudioCaptureResult) {
        guard var session else { return }

        let heldFor = now().timeIntervalSince(session.startedAt)
        guard result.framesWritten > 0 else {
            if heldFor < Self.blipHoldThreshold {
                // Accidental blip: released before the first buffer landed. Not an
                // error — and not worth storing (pill feedback only).
                lastSilenceReason = .noSpeech
                apply(.silenceOnly)
                discardSessionArtifacts()
                self.session = nil
                return
            }
            // Zero frames = nothing a Retry could ever transcribe. Show the
            // error in the pill, store no dead-end row (blip/discard doctrine).
            apply(.noAudioCaptured)
            discardSessionArtifacts()
            self.session = nil
            return
        }
        session.peakLevel = result.peakLevel
        self.session = session
        // Only meaningful together: a peak with no floor to compare it against
        // says nothing about the room, and would read as a measurement.
        let roomFloorDB = noiseFloor.floorDB
        let speechPeakDB = roomFloorDB == nil ? nil : noiseFloor.peakDB
        let separation = noiseFloor.measuredSNR
        updateMeta {
            $0.status = .recorded
            $0.audioDurationSeconds = result.durationSeconds
            $0.gapMarkers = result.gapMarkers
            // Recorded unconditionally — this is the data that will calibrate the
            // thresholds, and it has to exist before the behaviour that uses it.
            $0.noiseFloorDBFS = roomFloorDB
            $0.speechPeakDBFS = speechPeakDB
        }
        if let roomFloorDB, let speechPeakDB, let separation {
            Log.audio.info("room \(roomFloorDB, format: .fixed(precision: 1))dBFS, speech \(speechPeakDB, format: .fixed(precision: 1))dBFS, separation \(separation, format: .fixed(precision: 1))dB\(self.noiseHandlingActive ? " [experiment on]" : "")")
        }

        // Micro-clips can't contain a word — classify locally, never upload
        // (the API errors on them, which used to surface as Failed).
        guard result.durationSeconds >= Self.minimumSendableDuration else {
            lastSilenceReason = .noSpeech
            apply(.silenceOnly)
            discardSessionArtifacts()
            self.session = nil
            return
        }
        // Digital silence (muted mic, zero input volume) can't transcribe either:
        // the peak gate that already classifies the FAILURE response also decides
        // BEFORE upload — two pointless API round-trips per muted attempt
        // (production pass 2 P1 #29). Whisper-quiet speech peaks well above this.
        //
        // Two further clauses, both of which can only ever PREVENT a discard:
        //  - unmeasured loudness ⇒ upload. A wasted round-trip costs a fraction of
        //    a cent; a discarded session costs the user's words.
        //  - a quiet absolute peak that still rose clearly above the room is
        //    someone speaking softly in a quiet place, not a dead mic.
        let roseAboveRoom = (separation ?? .infinity) >= Self.discardSNRThreshold
        if !result.peakIsTrustworthy {
            Log.audio.info("peak unmeasured — uploading rather than guessing silence")
        } else if result.peakLevel < Self.silencePeakThreshold, !roseAboveRoom {
            lastSilenceReason = .noSpeech
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
                // Live first, when it is on. Inside this task on purpose: Esc
                // cancels inFlightTask, so a live finish outside it would be
                // invisible to cancellation and keep running after the user
                // gave up.
                if self.liveActiveForSession, let live = self.liveSession {
                    let liveResult = await live.finish(
                        deadline: TimeoutPolicy.liveFinal,
                        framesWritten: result.framesWritten
                    )
                    guard !Task.isCancelled else { return }
                    if let liveResult {
                        // Show the finished text in place of the guess before the
                        // pill moves on. This is the beat the landing page sells:
                        // the sentence visibly becomes the polished one.
                        // Show what the model took out, not just what it kept.
                        // Only when there is a real edit to show: an empty result
                        // means nothing was removed, or the texts could not be
                        // aligned, and either way the HUD just shows the sentence.
                        let diff = TranscriptDiff.segments(
                            verbatim: self.lastInterim,
                            cleaned: liveResult.cleanedTranscript
                        )
                        self.correctionSegments = diff.contains(where: \.isCut) ? diff : []
                        self.partialTranscript = liveResult.cleanedTranscript
                        self.correctedTranscript = liveResult.cleanedTranscript
                        await self.completeTranscription(
                            sessionID: sessionID, outcome: liveResult, startedAt: finalizeStartedAt
                        )
                        return
                    }
                    // nil means the stream was not clean — dropped audio, a dead
                    // socket, no final in time. The CAF has been accumulating the
                    // whole time, so this costs latency and nothing else.
                    Log.transcription.info("live result unusable — uploading the recording instead")
                }
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
                lastSilenceReason = .noSpeech
                apply(.silenceOnly)
                discardSessionArtifacts()
                session = nil
                return
            }
            // Loud room, nothing rising above it. The model is right that there is
            // no speech here, and calling it a failure hands the user an error
            // earcon, a red pill and a Retry that can never succeed — for the same
            // gesture that reads as a soft "didn't catch that" in a quiet room.
            // Classify honestly, but KEEP the recording: a high absolute peak means
            // we might be wrong, and Retry has to still exist when we are.
            if noiseHandlingActive,
               let snr = noiseFloor.measuredSNR,
               snr < Self.emptyTranscriptSNRThreshold {
                Log.audio.info("empty transcript with only \(snr, format: .fixed(precision: 1))dB above the room — no speech, not a failure")
                // NOT .silent: HistoryStore's visible filter ends with
                // `AND status != 'silent'`, and RetentionPolicy treats .silent as
                // purge-eligible — so a .silent row is invisible AND its audio is
                // deleted, while the pill says "saved to History". .failed is in
                // the visible set and gets a Retry button, and "tooNoisy" is not
                // in retryableRecords()'s auto-drain list, so nothing re-uploads
                // on its own.
                updateMeta { $0.status = .failed; $0.errorCode = "tooNoisy" }
                lastSilenceReason = .tooNoisy
                apply(.silenceOnly)
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
        var detail: String?
        switch error as? TranscriptionError {
        case .offline: failure = .network; code = "offline" // handled above
        case .badRequest(let message):
            failure = .badRequest; code = "bad_request"; detail = message
        case .modelUnavailable(let model, let message):
            failure = .modelAccess; code = "model"
            detail = message ?? "model \(model) not accessible"
        case .network: failure = .network; code = "network"
        case .auth: failure = .auth; code = "auth"
        case .rateLimitedDaily: failure = .quotaExhausted; code = "quota"
        case .rateLimitedTransient: failure = .rateLimited; code = "rate_limit"
        case .timeout: failure = .timeout; code = "timeout"
        case .emptyTranscript: failure = .validation; code = "empty"
        case .safetyBlocked: failure = .safetyBlocked; code = "safety"
        case nil: failure = .network; code = "unknown"
        }
        updateMeta { $0.status = .failed; $0.errorCode = code; $0.errorMessage = detail }
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
        micLevel = 0
        stopCapTimers()
        coachingHint = hint // feedback is immediate; the bookkeeping can wait

        // Teardown is async (it drains the HAL tail), so the keep-or-discard
        // decision — which needs the real recorded duration — completes after it.
        // The pill is already showing cancelled, so nothing visible waits.
        if let engine = capture {
            capture = nil
            Task { @MainActor [weak self] in
                let result = await engine.stop()
                self?.completeCancel(result: result)
            }
            return
        }
        completeCancel(result: nil)
    }

    private func completeCancel(result: AudioCaptureResult?) {
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
