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

/// The promise that makes live mode safe to turn on: a live session may improve
/// latency, but it may never cost words. Whenever it returns anything other than
/// a clean, reconciled transcript, the recording on disk is uploaded exactly as
/// it always was, and the user cannot tell the difference except in timing.
final class LiveFallbackTests: XCTestCase {

    /// A live session whose outcome the test dictates.
    final class ScriptedLive: LiveTranscribing, @unchecked Sendable {
        let outcome: TranscriptionResult?
        private(set) var enqueuedBytes = 0
        private(set) var began = false
        private(set) var aborted = false
        private(set) var finishedWithFrames: Int64?
        private let lock = NSLock()
        var beginError: Error?

        init(outcome: TranscriptionResult?) { self.outcome = outcome }

        func begin() async throws {
            if let beginError { throw beginError }
            began = true
        }
        nonisolated func enqueue(_ pcm: Data) {
            lock.lock(); enqueuedBytes += pcm.count; lock.unlock()
        }
        func finish(deadline: TimeInterval, framesWritten: Int64) async -> TranscriptionResult? {
            finishedWithFrames = framesWritten
            return outcome
        }
        func abort() async { aborted = true }
    }

    /// `LiveTranscriber.finish` is where truncation is caught. These exercise the
    /// real one against a scripted socket, because the reconciliation is the
    /// single check standing between a fluent partial transcript and the user's
    /// cursor.
    private func makeTranscriber(script: [Data], ring: PCMRing = PCMRing())
        -> (LiveTranscriber, LiveTranscriptionSessionTests.FakeTransport) {
        let transport = LiveTranscriptionSessionTests.FakeTransport(script: script)
        let session = LiveTranscriptionSession(transport: transport, setup: LiveSetup(), ring: ring)
        let transcriber = LiveTranscriber(session: session, modelID: "test-live", replacementRules: { [] })
        return (transcriber, transport)
    }

    private func frame(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// A clean stream whose bytes reconcile is usable.
    func testCleanReconciledStreamIsUsable() async throws {
        let (transcriber, _) = makeTranscriber(script: [
            frame(["setupComplete": [:] as [String: Any]]),
            frame(["serverContent": ["inputTranscription": ["text": "Ship it Friday."]]]),
        ])
        try await transcriber.begin()
        // 800 frames of audio = 1,600 bytes.
        transcriber.enqueue(Data(repeating: 0x01, count: 1_600))
        try await Task.sleep(nanoseconds: 150_000_000)
        let result = await transcriber.finish(deadline: 2.0, framesWritten: 800)
        XCTAssertEqual(result?.cleanedTranscript, "Ship it Friday.")
    }

    /// THE case. The socket took fewer bytes than the disk holds, so words are
    /// missing from the transcript even though it reads perfectly. Must be nil.
    func testByteMismatchIsRejectedEvenWithCleanText() async throws {
        let (transcriber, _) = makeTranscriber(script: [
            frame(["setupComplete": [:] as [String: Any]]),
            frame(["serverContent": ["inputTranscription": ["text": "…by Friday."]]]),
        ])
        try await transcriber.begin()
        transcriber.enqueue(Data(repeating: 0x01, count: 1_600))   // 800 frames streamed
        try await Task.sleep(nanoseconds: 150_000_000)
        // …but 5,000 frames reached the disk. 4,200 frames of speech never left.
        let result = await transcriber.finish(deadline: 2.0, framesWritten: 5_000)
        XCTAssertNil(result, "a transcript that reads fine but is missing audio must NOT be used")
    }

    /// More bytes accepted than written is equally wrong — it means the accounting
    /// is broken, and a broken counter cannot be trusted to catch truncation.
    func testMoreBytesThanFramesIsAlsoRejected() async throws {
        let (transcriber, _) = makeTranscriber(script: [
            frame(["setupComplete": [:] as [String: Any]]),
            frame(["serverContent": ["inputTranscription": ["text": "hello"]]]),
        ])
        try await transcriber.begin()
        transcriber.enqueue(Data(repeating: 0x01, count: 4_000))
        try await Task.sleep(nanoseconds: 150_000_000)
        let result = await transcriber.finish(deadline: 2.0, framesWritten: 100)
        XCTAssertNil(result, "impossible accounting must fail closed, not open")
    }

    func testNoFinalTranscriptFallsBack() async throws {
        let (transcriber, _) = makeTranscriber(script: [frame(["setupComplete": [:] as [String: Any]])])
        try await transcriber.begin()
        transcriber.enqueue(Data(repeating: 0x01, count: 1_600))
        let result = await transcriber.finish(deadline: 0.4, framesWritten: 800)
        XCTAssertNil(result)
    }

    func testServerErrorFallsBack() async throws {
        let (transcriber, _) = makeTranscriber(script: [
            frame(["setupComplete": [:] as [String: Any]]),
            frame(["serverContent": ["inputTranscription": ["text": "some words"]]]),
            frame(["error": ["message": "quota exhausted"]]),
        ])
        try await transcriber.begin()
        transcriber.enqueue(Data(repeating: 0x01, count: 1_600))
        try await Task.sleep(nanoseconds: 150_000_000)
        // A final did arrive, but so did an error — the session is not clean.
        let result = await transcriber.finish(deadline: 0.5, framesWritten: 800)
        XCTAssertNil(result, "an errored session must not contribute a transcript")
    }

    /// Dictionary corrections must run over live text, or turning live on would
    /// silently change how someone's name is spelled.
    func testReplacementRulesApplyToLiveText() async throws {
        let transport = LiveTranscriptionSessionTests.FakeTransport(script: [
            frame(["setupComplete": [:] as [String: Any]]),
            frame(["serverContent": ["inputTranscription": ["text": "send it to Amar"]]]),
        ])
        let session = LiveTranscriptionSession(transport: transport, setup: LiveSetup(), ring: PCMRing())
        let transcriber = LiveTranscriber(
            session: session, modelID: "test-live",
            replacementRules: { [ReplacementEngine.Rule(wrong: "Amar", right: "Ammaar")] }
        )
        try await transcriber.begin()
        transcriber.enqueue(Data(repeating: 0x01, count: 1_600))
        try await Task.sleep(nanoseconds: 150_000_000)
        let result = await transcriber.finish(deadline: 2.0, framesWritten: 800)
        XCTAssertEqual(result?.cleanedTranscript, "send it to Ammaar")
        XCTAssertEqual(result?.rawTranscript, "send it to Amar",
                       "raw must stay what the model actually returned")
    }

    /// A session that never opened must not throw at the caller — it just yields
    /// nothing, and the upload runs.
    func testSessionThatNeverOpenedYieldsNil() async {
        let (transcriber, _) = makeTranscriber(script: [])
        let result = await transcriber.finish(deadline: 0.3, framesWritten: 800)
        XCTAssertNil(result)
    }
}
