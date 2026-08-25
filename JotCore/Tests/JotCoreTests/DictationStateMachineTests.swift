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

import XCTest
@testable import JotCore

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
        let final = run([.hotkeyBegin, .engineStarted, .engineFailed(.audio)])
        XCTAssertEqual(final, .finalizing, "captured audio must flow to finalize, not be dropped")
    }

    func testWarmingEngineFailureCarriesHonestReason() {
        let final = run([.hotkeyBegin, .engineFailed(.noMicrophone)])
        XCTAssertEqual(final, .failed(.noMicrophone))
    }

    func testTranscriptionFailureCarriesReason() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .transcriptFailed(.auth)])
        XCTAssertEqual(final, .failed(.auth))
    }

    func testFocusChangeNeverBlindPastes() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .transcriptReady, .frontmostChangedAwaitingChip])
        XCTAssertEqual(final, .done(.awaitingChip))
    }

    func testSecureFieldHoldsTextInHistoryOnly() {
        let final = run([.hotkeyBegin, .engineStarted, .finalize, .audioFinalized, .transcriptReady, .insertionBlockedSecure])
        XCTAssertEqual(final, .done(.heldForSecureField))
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
