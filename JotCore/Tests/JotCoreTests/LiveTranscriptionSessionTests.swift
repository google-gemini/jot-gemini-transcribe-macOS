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

/// Every way a live session can end, driven against a scripted socket so the
/// failure modes that matter are exercised on every build rather than only when
/// someone's wifi drops mid-sentence.
final class LiveTranscriptionSessionTests: XCTestCase {

    /// A socket that says what the test tells it to say.
    final class FakeTransport: LiveTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var inbox: [Data]
        private(set) var sent: [Data] = []
        var connectError: Error?
        var sendErrorAfter: Int?
        var receiveHangs = false
        private(set) var closeCount = 0

        init(script: [Data]) { self.inbox = script }

        func connect() async throws {
            if let connectError { throw connectError }
        }

        func send(_ data: Data) async throws {
            lock.lock()
            let count = sent.count
            let limit = sendErrorAfter
            lock.unlock()
            if let limit, count >= limit {
                throw URLError(.networkConnectionLost)
            }
            lock.lock(); sent.append(data); lock.unlock()
        }

        func receive() async throws -> Data {
            if receiveHangs {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw URLError(.timedOut)
            }
            lock.lock()
            let next = inbox.isEmpty ? nil : inbox.removeFirst()
            lock.unlock()
            if let next { return next }
            // Nothing left to say: park rather than spinning, like a real socket
            // waiting on a server that has gone quiet.
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        }

        func close() { lock.lock(); closeCount += 1; lock.unlock() }

        /// What was actually put on the wire, in order, as decoded JSON keys.
        var sentKinds: [String] {
            lock.lock(); defer { lock.unlock() }
            return sent.compactMap { data in
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                if root["setup"] != nil { return "setup" }
                guard let realtime = root["realtimeInput"] as? [String: Any] else { return nil }
                if realtime["activityStart"] != nil { return "activityStart" }
                if realtime["activityEnd"] != nil { return "activityEnd" }
                if realtime["audio"] != nil { return "audio" }
                return nil
            }
        }
    }

    private func frame(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func setupCompleteFrame() -> Data { frame(["setupComplete": [:] as [String: Any]]) }
    private func finalFrame(_ text: String) -> Data {
        frame(["serverContent": ["inputTranscription": ["text": text]]])
    }
    private func partialFrame(_ text: String) -> Data {
        frame(["serverContent": ["interimInputTranscription": ["text": text]]])
    }

    private func makeSession(_ transport: FakeTransport, ring: PCMRing = PCMRing()) -> LiveTranscriptionSession {
        LiveTranscriptionSession(transport: transport, setup: LiveSetup(), ring: ring)
    }

    // MARK: - The happy path

    func testCleanSessionCompletesWithFinalText() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("Ship it on Friday.")])
        let session = makeSession(transport)
        try await session.start()
        session.enqueue(Data(repeating: 0x01, count: 3_328))
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 2.0)
        XCTAssertEqual(outcome, .completed("Ship it on Friday."))
    }

    /// The ordering guarantee that stops the user's last words being cut off:
    /// activityEnd must reach the wire AFTER every audio chunk queued before it.
    func testActivityEndNeverOvertakesQueuedAudio() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("done")])
        let session = makeSession(transport)
        try await session.start()
        for _ in 0..<12 { session.enqueue(Data(repeating: 0x02, count: 3_328)) }
        _ = await session.finish(deadline: 2.0)

        let kinds = transport.sentKinds
        let endIndex = try XCTUnwrap(kinds.firstIndex(of: "activityEnd"))
        let audioIndices = kinds.enumerated().filter { $0.element == "audio" }.map(\.offset)
        XCTAssertFalse(audioIndices.isEmpty, "audio must actually have been sent")
        XCTAssertTrue(audioIndices.allSatisfy { $0 < endIndex },
                      "every audio chunk must precede activityEnd — the server finalizes on what it has")
    }

    func testSetupIsSentBeforeActivityStart() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("x")])
        let session = makeSession(transport)
        try await session.start()
        _ = await session.finish(deadline: 1.0)
        let kinds = transport.sentKinds
        XCTAssertEqual(kinds.first, "setup")
        XCTAssertEqual(kinds.dropFirst().first, "activityStart")
    }

    // MARK: - Everything that must fall back

    /// The failure the whole design is arranged around: dropped audio yields a
    /// fluent-but-truncated transcript. It must NEVER be promoted.
    func testDroppedAudioDisqualifiesTheSession() async throws {
        // A ring so small that streaming more than a second guarantees eviction.
        let ring = PCMRing(seconds: 1.0)
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("…by Friday.")])
        let session = LiveTranscriptionSession(transport: transport, setup: LiveSetup(), ring: ring)
        // Fill before start so nothing can drain it: the socket is not pumping yet.
        for _ in 0..<40 { ring.append(Data(repeating: 0x03, count: 3_328)) }
        XCTAssertTrue(ring.didDrop, "precondition: the ring must have evicted")

        try await session.start()
        let outcome = await session.finish(deadline: 1.0)
        guard case .unusable(let why) = outcome else {
            return XCTFail("a truncated stream must be unusable, got \(outcome)")
        }
        XCTAssertTrue(why.contains("truncated"), "the reason should name truncation, got: \(why)")
    }

    func testSetupTimeoutIsThrownNotSwallowed() async {
        let transport = FakeTransport(script: [])
        transport.receiveHangs = true
        let session = makeSession(transport)
        do {
            try await session.start(setupTimeout: 0.2)
            XCTFail("start must throw when setup never completes")
        } catch {
            // Any throw is correct — the caller falls back to batch either way.
        }
    }

    func testConnectFailureThrows() async {
        let transport = FakeTransport(script: [])
        transport.connectError = URLError(.notConnectedToInternet)
        let session = makeSession(transport)
        do {
            try await session.start(setupTimeout: 0.5)
            XCTFail("start must throw when the socket cannot connect")
        } catch {}
    }

    func testServerErrorEnvelopeIsRefused() async {
        let transport = FakeTransport(script: [frame(["error": ["message": "API key not valid"]])])
        let session = makeSession(transport)
        do {
            try await session.start(setupTimeout: 1.0)
            XCTFail("an error envelope during setup must throw")
        } catch {
            XCTAssertEqual(error as? LiveError, .refused("API key not valid"))
        }
    }

    func testNoFinalBeforeDeadlineIsUnusable() async throws {
        // Setup succeeds, then the server says nothing more.
        let transport = FakeTransport(script: [setupCompleteFrame()])
        let session = makeSession(transport)
        try await session.start()
        session.enqueue(Data(repeating: 0x04, count: 1_024))
        let outcome = await session.finish(deadline: 0.4)
        guard case .unusable = outcome else {
            return XCTFail("no final transcript must be unusable, got \(outcome)")
        }
    }

    func testGoAwayMakesTheSessionUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), frame(["goAway": [:] as [String: Any]])])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 0.5)
        guard case .unusable = outcome else {
            return XCTFail("goAway must be unusable, got \(outcome)")
        }
    }

    func testSendFailureMidStreamIsUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("partial words")])
        let session = makeSession(transport)
        try await session.start()
        // setup + activityStart already sent; fail on the next write.
        transport.sendErrorAfter = 2
        for _ in 0..<4 { session.enqueue(Data(repeating: 0x05, count: 3_328)) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let outcome = await session.finish(deadline: 0.5)
        guard case .unusable = outcome else {
            return XCTFail("a mid-stream send failure must be unusable, got \(outcome)")
        }
    }

    // MARK: - Partials must never become the transcript

    func testPartialsAreNeverPromotedToTheOutcome() async throws {
        let transport = FakeTransport(script: [
            setupCompleteFrame(),
            partialFrame("ship it on fry"),
            partialFrame("ship it on friday"),
            finalFrame("Ship it on Friday."),
        ])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        let outcome = await session.finish(deadline: 1.5)
        XCTAssertEqual(outcome, .completed("Ship it on Friday."),
                       "the outcome must be the FINAL text, never the last interim")
    }

    func testPartialOnlySessionIsUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), partialFrame("half a thought")])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 0.4)
        guard case .unusable = outcome else {
            return XCTFail("interim text alone must never be usable, got \(outcome)")
        }
    }

    // MARK: - Lifecycle

    func testAbortIsIdempotent() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("x")])
        let session = makeSession(transport)
        try await session.start()
        await session.abort()
        await session.abort()
        await session.abort()
        XCTAssertEqual(transport.closeCount, 1, "close must happen exactly once however many aborts arrive")
    }

    func testFinishBeforeStartIsUnusableNotACrash() async {
        let transport = FakeTransport(script: [])
        let session = makeSession(transport)
        let outcome = await session.finish(deadline: 0.2)
        guard case .unusable = outcome else {
            return XCTFail("finishing a session that never started must be unusable")
        }
    }

    func testEmptyFinalIsUnusable() async throws {
        let transport = FakeTransport(script: [setupCompleteFrame(), finalFrame("   ")])
        let session = makeSession(transport)
        try await session.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        let outcome = await session.finish(deadline: 0.5)
        guard case .unusable = outcome else {
            return XCTFail("whitespace-only text must not be inserted, got \(outcome)")
        }
    }
}
