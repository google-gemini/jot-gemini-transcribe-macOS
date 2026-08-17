import XCTest
@testable import TranscribeCore

@MainActor
final class DictationCoordinatorTests: XCTestCase {

    // MARK: Fakes

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var onDeviceChange: ((String) -> Void)?
        var startError: Error?
        var result = AudioCaptureResult(framesWritten: 16_000, durationSeconds: 1.0)
        private(set) var started = false
        private(set) var stopCount = 0

        func start(writingTo url: URL) throws {
            if let startError { throw startError }
            started = true
        }
        func stop() -> AudioCaptureResult {
            stopCount += 1
            return result
        }
    }

    struct FakeTranscription: TranscriptionServicing {
        var result: Result<TranscriptionResult, TranscriptionError> =
            .success(TranscriptionResult(rawTranscript: "raw", cleanedTranscript: "clean", modelID: "test"))
        func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
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

    private func makeCoordinator(
        transcription: FakeTranscription = FakeTranscription()
    ) -> DictationCoordinator {
        capture = FakeCapture()
        inserter = FakeInserter()
        return DictationCoordinator(
            audioFactory: { [capture] in capture! },
            transcription: transcription,
            insertion: inserter
        )
    }

    private func settle() async {
        // Drain the finalize Task chain.
        for _ in 0..<10 { await Task.yield() }
    }

    // MARK: Tests

    func testHappyPathInserts() async {
        let c = makeCoordinator()
        c.handle(.begin)
        XCTAssertEqual(c.state, .recording(locked: false))
        XCTAssertTrue(capture.started)

        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .done(.inserted))
        XCTAssertEqual(inserter.insertedText, "clean")
        XCTAssertEqual(c.lastResult, "clean")
    }

    func testLockInMarksHandsFree() {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.lockIn)
        XCTAssertEqual(c.state, .recording(locked: true))
    }

    func testZeroFramesIsNoAudioFailure() async {
        let c = makeCoordinator()
        c.handle(.begin)
        capture.result = AudioCaptureResult(framesWritten: 0, durationSeconds: 0)
        c.handle(.finalize)
        await settle()
        XCTAssertEqual(c.state, .failed(.noAudio))
        XCTAssertNil(inserter.insertedText)
    }

    func testEngineStartFailure() {
        let c = makeCoordinator()
        capture.startError = AudioCaptureEngine.CaptureError.noInputDevice
        c.handle(.begin)
        XCTAssertEqual(c.state, .failed(.audio))
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

    func testCancelStopsCapture() {
        let c = makeCoordinator()
        c.handle(.begin)
        c.handle(.cancel)
        XCTAssertEqual(c.state, .cancelled)
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
        XCTAssertEqual(c.state, .recording(locked: false))
    }
}
