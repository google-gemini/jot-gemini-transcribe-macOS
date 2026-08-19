import XCTest
@testable import JotCore

@MainActor
final class DictationCoordinatorTests: XCTestCase {

    // MARK: Fakes

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var onDeviceChange: ((String) -> Void)?
        var onWriteFailure: (() -> Void)?
        var onEngineDied: ((String) -> Void)?
        var startError: Error?
        var result = AudioCaptureResult(framesWritten: 16_000, durationSeconds: 1.0)
        private(set) var started = false
        private(set) var stopCount = 0

        func start(writingTo url: URL) throws {
            if let startError { throw startError }
            started = true
        }
        func stop() async -> AudioCaptureResult {
            stopCount += 1
            return result
        }
    }

    struct FakeTranscription: TranscriptionServicing {
        var result: Result<TranscriptionResult, TranscriptionError> =
            .success(TranscriptionResult(rawTranscript: "raw", cleanedTranscript: "clean", modelID: "test"))
        /// Simulates a slow round-trip so tests can act mid-flight.
        var delayNanos: UInt64 = 0
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
            if delayNanos > 0 {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
            switch result {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    final class FakeInserter: TextInserting {
        var outcome: InsertionOutcome = .inserted
        private(set) var insertedText: String?
        func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
            insertedText = text
            return outcome
        }
    }

    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var fakeNow = Date()
    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        // Never touch the user's real recordings from tests.
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-tests-\(UUID().uuidString)", isDirectory: true)
        FileLayout.overrideRoot = sandbox
    }

    override func tearDown() {
        FileLayout.overrideRoot = nil
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        super.tearDown()
    }

    private func makeCoordinator(
        transcription: FakeTranscription = FakeTranscription()
    ) -> DictationCoordinator {
        capture = FakeCapture()
        inserter = FakeInserter()
        fakeNow = Date()
        let coordinator = DictationCoordinator(
            audioFactory: { [capture] in capture! },
            transcription: transcription,
            insertion: inserter,
            now: { [weak self] in self?.fakeNow ?? Date() }
        )
        lastCoordinator = coordinator
        return coordinator
    }

    private var lastCoordinator: DictationCoordinator?

    /// Drain the deferred engine start (begin queues it one main-actor tick out
    /// so the pill can paint before the engine blocks — the latency fix).
    private func pump() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func settle() async {
        // Drain the finalize Task chain — poll for a terminal state rather than a
        // fixed yield count (which flaked under cold-start scheduling variance).
        for _ in 0..<200 {
            if lastCoordinator?.state.isTerminal ?? true { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Tests

    /// Releasing the key mid-word must not clip the ending: capture carries
    /// past key-up while speech is still present, then stops once it's quiet.
    func testStillSpeakingAtKeyUpCarriesCapture() async {
        let c = makeCoordinator()
        c.handle(.begin)
        await pump()
        capture.onLevel?(0.6) // mid-word at the moment of release
        await pump()
        c.handle(.finalize)
        await pump()
        XCTAssertEqual(capture.stopCount, 0, "still talking — the mic stays open")
        capture.onLevel?(0.0) // they finish
        await settle()
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(c.state, .done(.inserted))
    }

    /// The common case pays nothing: a quiet release stops immediately.
    func testQuietReleaseStopsImmediately() async {
        let c = makeCoordinator()
        c.handle(.begin)
        await pump()
        capture.onLevel?(0.01)
        await pump()
        c.handle(.finalize)
        await pump()
        XCTAssertEqual(capture.stopCount, 1, "already quiet — no carry-over latency")
    }

    func testHappyPathInserts() async {
        let c = makeCoordinator()
        c.handle(.begin)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: false))
        XCTAssertTrue(capture.started)

        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        XCTAssertEqual(inserter.insertedText, "clean")
        XCTAssertEqual(c.lastResult, "clean")
    }

    func testLockInMarksHandsFree() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.lockIn) // arrives during warming — latched, applied on engineStarted
        await pump()
        XCTAssertEqual(c.state, .recording(locked: true))
    }

    func testZeroFramesOnRealHoldIsNoAudioFailure() async {
        let c = makeCoordinator()
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        fakeNow += 2.0 // a deliberate 2s hold with zero buffers = engine race (F21)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.noAudio))
        XCTAssertNil(inserter.insertedText)
    }

    func testZeroFramesOnQuickBlipIsSilent() async {
        let c = makeCoordinator()
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        c.handle(.finalize) // released almost immediately — first buffer never landed
        await settle()
        XCTAssertEqual(c.state, .done(.silent), "an accidental blip is not a mic failure")
    }

    // Storage policy: what History doesn't show, we don't store.

    func testSilentSessionDiscardsArtifacts() async {
        let c = makeCoordinator()
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 3_000, durationSeconds: 0.19)
        fakeNow += 2.0
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.silent))
        XCTAssertNotNil(discarded, "micro-clip artifacts must be discarded")
    }

    func testShortCancelDiscardsButLongCancelKeeps() async {
        let c = makeCoordinator()
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        // Short cancel → discard.
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 16_000, durationSeconds: 1.0)
        c.handle(.cancel)
        await pump()
        XCTAssertNotNil(discarded, "1s cancel leaves no trace")
        // Long cancel → kept (recoverable from History).
        discarded = nil
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 16_000 * 60, durationSeconds: 60)
        c.handle(.cancel)
        await pump()
        XCTAssertNil(discarded, "a 60s cancelled recording stays recoverable")
    }

    func testMicroClipNeverUploads() async {
        var t = FakeTranscription()
        t.result = .failure(.network("should never be called")) // upload would fail loudly
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 3_000, durationSeconds: 0.19)
        fakeNow += 2.0
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.silent), "0.19s can't contain a word — classified locally")
    }

    func testEngineStartFailureNamesTheMissingMic() async {
        let c = makeCoordinator()
        capture.startError = AudioCaptureEngine.CaptureError.noInputDevice
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        c.handle(.begin)
        await pump()
        // Honest taxonomy: no input device ≠ "mic didn't start"; and zero frames
        // means nothing storable — no dead-end Failed row (production pass 2).
        XCTAssertEqual(c.state, .failed(.noMicrophone))
        XCTAssertNotNil(discarded)
    }

    func testTranscriptionAuthFailure() async {
        var t = FakeTranscription()
        t.result = .failure(.auth)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.auth))
    }

    // Production pass 2 P0: Esc during transcription must honor the keep rule
    // using the PERSISTED duration — capture is gone by then, and reading 0
    // destroyed recordings of any length.

    func testEscDuringTranscribingKeepsLongRecording() async {
        var t = FakeTranscription()
        t.delayNanos = 2_000_000_000 // still in flight when cancel lands
        let c = makeCoordinator(transcription: t)
        capture.result = AudioCaptureResult(framesWritten: 16_000 * 60, durationSeconds: 60)
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }
        var lastMeta: SessionMeta?
        c.onSessionUpdate = { meta, _ in lastMeta = meta }

        c.handle(.begin)
        c.handle(.finalize)
        await pump()
        XCTAssertEqual(c.state, .transcribing)
        c.handle(.cancel)

        XCTAssertEqual(c.state, .cancelled)
        XCTAssertNil(discarded, "a 60s recording must survive an in-flight Esc")
        XCTAssertEqual(lastMeta?.status, .cancelled)
        XCTAssertEqual(lastMeta?.audioDurationSeconds, 60)
    }

    func testEscDuringTranscribingStillDiscardsShortRecording() async {
        var t = FakeTranscription()
        t.delayNanos = 2_000_000_000
        let c = makeCoordinator(transcription: t)
        capture.result = AudioCaptureResult(framesWritten: 16_000 * 3, durationSeconds: 3)
        var discarded: UUID?
        c.onSessionDiscard = { discarded = $0 }

        c.handle(.begin)
        c.handle(.finalize)
        c.handle(.cancel)

        XCTAssertEqual(c.state, .cancelled)
        XCTAssertNotNil(discarded, "a 3s deliberate cancel still discards")
    }

    // Production pass 2 P0: a second finalize while in flight must be a pure
    // no-op — it used to stop capture again and clobber meta to failed/no_audio.

    func testSecondFinalizeWhileInFlightIsIgnored() async {
        var t = FakeTranscription()
        t.delayNanos = 60_000_000
        let c = makeCoordinator(transcription: t)
        var statuses: [SessionMeta.Status] = []
        c.onSessionUpdate = { meta, _ in statuses.append(meta.status) }

        c.handle(.begin)
        c.handle(.finalize)
        await pump()
        XCTAssertEqual(c.state, .transcribing)
        c.handle(.finalize) // pill Stop double-click / second jot://stop
        XCTAssertEqual(c.state, .transcribing)
        await pump()
        XCTAssertEqual(capture.stopCount, 1, "second finalize must not stop capture again")

        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        XCTAssertFalse(statuses.contains(.failed), "no false Failed row from the double stop")
    }

    // Production pass 2 P0: a rolled fn+letter chord during a hands-free session
    // must STOP it (the fn press is a stop gesture), never silently destroy it.

    func testAccidentalChordFinalizesHandsFreeSession() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.lockIn)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: true))
        c.handle(.abortAccidental)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted), "chord acts as stop — words land")
    }

    func testAccidentalChordStillCancelsOwnYoungSession() async {
        let c = makeCoordinator()
        c.handle(.begin)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: false))
        c.handle(.abortAccidental)
        XCTAssertEqual(c.state, .cancelled)
    }

    func testAccidentalChordIgnoredWhileInFlight() async {
        var t = FakeTranscription()
        t.delayNanos = 60_000_000
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        c.handle(.abortAccidental)
        await pump() // capture teardown (tail drain) completes off the main path
        XCTAssertEqual(c.state, .transcribing, "transcript is sacred")
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
    }

    func testCancelStopsCapture() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.cancel)
        XCTAssertEqual(c.state, .cancelled, "feedback is immediate, teardown is not")
        await pump()
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertNil(inserter.insertedText)
    }

    func testShortTapHintSetsCoaching() {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.shortTapHint)
        XCTAssertEqual(c.state, .cancelled)
        XCTAssertEqual(c.coachingHint, "Hold to talk · tap Space while holding for hands-free")
    }

    // Audit #1: a quick tap must never destroy an in-flight session.

    func testTapDuringTranscriptionDoesNotCancelIt() async {
        var t = FakeTranscription()
        t.delayNanos = 60_000_000 // 60ms in flight
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        // The phantom tap lands while the transcript is in flight:
        c.handle(.begin)        // ignored (session active)
        c.handle(.shortTapHint) // must NOT cancel
        await settle()
        XCTAssertEqual(c.state, .done(.inserted), "the in-flight transcript is sacred")
        XCTAssertEqual(inserter.insertedText, "clean")
    }

    func testTapStopsUIStartedHandsFree() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.lockIn) // UI-started hands-free (dot/menu)
        await pump()      // engine comes up, latched lock applies
        c.handle(.shortTapHint) // natural quick tap = stop
        await settle()
        XCTAssertEqual(c.state, .done(.inserted), "a tap finalizes hands-free instead of cancelling it")
    }

    func testCancelDuringInsertingRejectedCleanly() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        // A stray cancel after completion must not corrupt anything (audit #10).
        c.handle(.cancel)
        XCTAssertEqual(c.state, .done(.inserted))
    }

    // Audit #3: permanent API failures are terminal, not retryable-forever.

    func testBadRequestSurfacesAsItsOwnFailure() async {
        var t = FakeTranscription()
        t.result = .failure(.badRequest("malformed request"))
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        // Surfaced as its own failure now — not buried under .validation.
        XCTAssertEqual(c.state, .failed(.badRequest))
    }

    // Silence is judged by audio energy, not duration (F9a vs F9b — dogfood bug).

    func testQuietLongHoldIsNoSpeechNotFailed() async {
        var t = FakeTranscription()
        t.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 48_000, durationSeconds: 3.0, peakLevel: 0.01)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.silent), "a quiet 3s hold is 'no speech', never Failed")
    }

    func testLoudShortUtteranceWithEmptyTranscriptIsAFailure() async {
        // Audit #13: a loud 1s "Hi!" that comes back empty is a dropped transcript.
        var t = FakeTranscription()
        t.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 16_000, durationSeconds: 1.0, peakLevel: 0.6)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.validation), "speech energy + no transcript = retryable failure")
    }

    func testEmptyTranscriptWithSpeechEnergyIsARealFailure() async {
        var t = FakeTranscription()
        t.result = .failure(.emptyTranscript)
        let c = makeCoordinator(transcription: t)
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 48_000, durationSeconds: 3.0, peakLevel: 0.5)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.validation), "speech energy + no transcript = retryable failure")
    }

    func testClipboardFallbackOutcome() async {
        let c = makeCoordinator()
        c.handle(.begin)
        inserter.outcome = .fellBackToClipboard
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.copiedToClipboard))
    }

    func testBeginWhileActiveIsIgnored() {
        let c = makeCoordinator()
        c.handle(.begin)
        let stateBefore = c.state
        c.handle(.begin)
        XCTAssertEqual(c.state, stateBefore)
    }

    func testNewSessionAfterCompletion() async {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        // FakeCapture is reused by the factory; reset its state via a new begin.
        c.handle(.begin)
        await pump()
        XCTAssertEqual(c.state, .recording(locked: false))
    }
}
