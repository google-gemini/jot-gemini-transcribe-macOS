import XCTest
@testable import TranscribeCore

final class DictationStateMachineTests: XCTestCase {
    private func run(_ events: [DictationEvent], from start: DictationState = .idle) -> DictationState {
        events.reduce(start) { state, event in
            DictationStateMachine.transition(state, on: event) ?? state
        }
    }

    // MARK: Happy paths

    func testHoldSpeakReleaseInsert() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .transcriptReady, .inserted])
        XCTAssertEqual(final, .done(.inserted))
    }

    func testHandsFreeLockThenStop() {
        var state = run([.hotkeyBegin, .engineStarted, .lockIn])
        XCTAssertEqual(state, .recording(locked: true))
        state = run([.finalize, .audioFinalized, .transcriptReady, .inserted], from: state)
        XCTAssertEqual(state, .done(.inserted))
    }

    // MARK: Cancellation & accidents

    func testEscCancelsWhileRecording() {
        XCTAssertEqual(run([.hotkeyBegin, .engineStarted, .cancel]), .cancelled)
    }

    func testAccidentalChordAbortsWarming() {
        XCTAssertEqual(run([.hotkeyBegin, .abortAccidental]), .cancelled)
    }

    func testEscCancelsDuringTranscription() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .cancel])
        XCTAssertEqual(final, .cancelled)
    }

    func testCannotCancelDuringInsertion() {
        let inserting = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .transcriptReady])
        XCTAssertEqual(inserting, .inserting)
        XCTAssertNil(DictationStateMachine.transition(inserting, on: .cancel))
    }

    // MARK: Failure paths (never lose words)

    func testReleaseBeforeEngineStartStillFinalizes() {
        // Ultra-quick press-release: audio from t=0 must still be processed.
        XCTAssertEqual(run([.hotkeyBegin, .finalize]), .finalizing)
    }

    func testZeroBuffersIsAnErrorNeverEmptyTranscript() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .noAudioCaptured])
        XCTAssertEqual(final, .failed(.noAudio))
    }

    func testSilenceOnlyIsCalmNotAnError() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .silenceOnly])
        XCTAssertEqual(final, .done(.silent))
    }

    func testOfflineQueuesForRetry() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .queuedForRetry])
        XCTAssertEqual(final, .done(.queuedForRetry))
    }

    func testMidRecordingEngineDeathPreservesAudio() {
        let final = run([.hotkeyBegin, .engineStarted, .engineFailed])
        XCTAssertEqual(final, .finalizing, "captured audio must flow to finalize, not be dropped")
    }

    func testTranscriptionFailureCarriesReason() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .transcriptFailed(.auth)])
        XCTAssertEqual(final, .failed(.auth))
    }

    func testFocusChangeNeverBlindPastes() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .transcriptReady, .frontmostChangedAwaitingChip])
        XCTAssertEqual(final, .done(.awaitingChip))
    }

    // MARK: Invalid / stale events are ignored

    func testStaleEventsReturnNil() {
        XCTAssertNil(DictationStateMachine.transition(.idle, on: .finalize))
        XCTAssertNil(DictationStateMachine.transition(.idle, on: .transcriptReady))
        XCTAssertNil(DictationStateMachine.transition(.done(.inserted), on: .inserted))
        XCTAssertNil(DictationStateMachine.transition(.cancelled, on: .transcriptReady))
        XCTAssertNil(DictationStateMachine.transition(.recording(locked: false), on: .hotkeyBegin))
    }

    func testDoubleLockIsIgnored() {
        let locked = DictationState.recording(locked: true)
        XCTAssertNil(DictationStateMachine.transition(locked, on: .lockIn))
    }

    func testTerminalStatesAreTerminal() {
        for state in [DictationState.done(.inserted), .cancelled, .failed(.network)] {
            XCTAssertTrue(state.isTerminal)
            for event in [DictationEvent.hotkeyBegin, .finalize, .transcriptReady, .inserted] {
                XCTAssertNil(DictationStateMachine.transition(state, on: event))
            }
        }
    }
}
