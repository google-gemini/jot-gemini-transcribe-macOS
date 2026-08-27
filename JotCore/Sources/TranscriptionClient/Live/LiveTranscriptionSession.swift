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

/// The socket, behind a protocol so every failure mode in this file can be
/// exercised against a scripted fake with no network: setup timeout, mid-stream
/// drop, clean finish, server goAway, double-abort.
public protocol LiveTransport: AnyObject, Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// How a live session ended. Only `.completed` may replace the real transcript,
/// and even then only after the caller has reconciled the byte count.
public enum LiveOutcome: Equatable, Sendable {
    /// Clean: setup completed, nothing dropped, activityEnd acknowledged, a final
    /// transcript arrived before the deadline.
    case completed(String)
    /// Anything else. The batch path over the CAF takes over; the words are on
    /// disk regardless. The string is for the log, never for the user.
    case unusable(String)
}

/// One live transcription session over one WebSocket.
///
/// The shape is dictated by two hard constraints:
///
/// 1. **The audio write queue must never wait for this.** `enqueue` is
///    `nonisolated`, takes no lock the socket holds, and cannot await. It appends
///    to a ring and signals; that is all.
///
/// 2. **`activityEnd` must never overtake the audio in front of it.** The server
///    finalizes on what it has received, so an end signal that jumps the queue
///    silently truncates the user's last words — precisely the tail that
///    `awaitTailBuffer` exists to rescue. Control items therefore travel *in
///    band*, through the same channel as the audio wakeups, and the send loop
///    drains the ring completely before it acts on one.
public actor LiveTranscriptionSession {

    private enum Command: Sendable {
        case pcmAvailable
        case endActivity
    }

    private let transport: LiveTransport
    private let setup: LiveSetup
    public let ring: PCMRing

    private let commands: AsyncStream<Command>
    private let commandSink: AsyncStream<Command>.Continuation

    private var sendLoop: Task<Void, Never>?
    private var receiveLoop: Task<Void, Never>?

    private var finals: [String] = []
    private var latestPartial: String = ""
    private var failure: String?
    private var didSetup = false
    private var activityEndFlushed = false
    private var closed = false

    /// Partials for the HUD. Separate from the outcome on purpose — nothing that
    /// arrives here is allowed to become the transcript.
    public let partials: AsyncStream<String>
    private let partialSink: AsyncStream<String>.Continuation

    public init(transport: LiveTransport, setup: LiveSetup, ring: PCMRing = PCMRing()) {
        self.transport = transport
        self.setup = setup
        self.ring = ring
        // Control items must never be dropped, so this stream is unbounded — it
        // carries at most a handful of wakeups, not audio. The audio is in the
        // ring, which is the only thing with a drop policy.
        (self.commands, self.commandSink) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        (self.partials, self.partialSink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Called from the audio write queue. Must not block, must not await.
    public nonisolated func enqueue(_ pcm: Data) {
        ring.append(pcm)
        commandSink.yield(.pcmAvailable)
    }

    /// Connects, handshakes, and opens the pumps. Throws if the socket or the
    /// credential is refused — the caller falls back to the batch path.
    public func start(setupTimeout: TimeInterval = 5.0) async throws {
        try await transport.connect()
        try await transport.send(LiveProtocol.setupFrame(setup))

        // Wait for setupComplete before streaming. Audio arriving meanwhile is
        // already accumulating in the ring, so nothing is lost by waiting.
        //
        // Every receive is raced against the clock. Checking the deadline only
        // between receives would not bound anything: a socket that connects and
        // then says nothing — a proxy holding the upgrade, a server that accepted
        // the TCP connection and stalled — parks here for the transport's own
        // 30s timeout, and dictation cannot fall back to the batch path until
        // this returns. The bound has to be on the wait itself.
        let deadline = Date().addingTimeInterval(setupTimeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let frame = try await Self.receive(from: transport, within: remaining)
            guard let event = LiveProtocol.decode(frame) else { continue }
            switch event {
            case .setupComplete:
                didSetup = true
            case .failed(let why):
                throw LiveError.refused(why)
            default:
                continue
            }
            break
        }
        guard didSetup else { throw LiveError.setupTimedOut }

        try await transport.send(LiveProtocol.activityStartFrame())
        startPumps()
    }

    /// Races a receive against a deadline. Returns the frame, or throws
    /// `LiveError.setupTimedOut` — either way it returns *promptly*, which is the
    /// whole point: the caller's fallback cannot start until this does.
    private static func receive(from transport: LiveTransport, within seconds: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await transport.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw LiveError.setupTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LiveError.setupTimedOut }
            return first
        }
    }

    private func startPumps() {
        receiveLoop = Task { [weak self] in await self?.runReceiveLoop() }
        sendLoop = Task { [weak self] in await self?.runSendLoop() }
    }

    private func runSendLoop() async {
        for await command in commands {
            if closed { return }
            // Drain the ring FIRST, on every command. This is what keeps
            // activityEnd behind the audio it must not overtake.
            for chunk in ring.drain() {
                do {
                    try await transport.send(LiveProtocol.audioFrame(chunk))
                    ring.markAccepted(chunk.count)
                } catch {
                    recordFailure("send failed: \(error)")
                    return
                }
            }
            if case .endActivity = command {
                do {
                    try await transport.send(LiveProtocol.activityEndFrame())
                } catch {
                    recordFailure("activityEnd failed: \(error)")
                }
                activityEndFlushed = true
                return
            }
        }
    }

    private func runReceiveLoop() async {
        while !closed {
            do {
                let frame = try await transport.receive()
                guard let event = LiveProtocol.decode(frame) else { continue }
                switch event {
                case .partial(let text):
                    latestPartial = text
                    partialSink.yield(text)
                case .final(let text):
                    finals.append(text)
                    latestPartial = ""
                case .goAway:
                    recordFailure("server sent goAway")
                    return
                case .failed(let why):
                    recordFailure(why)
                    return
                case .setupComplete:
                    continue
                }
            } catch {
                if !closed { recordFailure("receive failed: \(error)") }
                return
            }
        }
    }

    private func recordFailure(_ why: String) {
        if failure == nil { failure = why }
    }

    /// Ends the turn and waits for the server's last word.
    ///
    /// Called only after `AudioCaptureEngine.stop()` has returned, because audio
    /// keeps arriving through the tail drain and the trailing-capture window —
    /// key-up is not the end of speech.
    public func finish(deadline: TimeInterval = 6.0) async -> LiveOutcome {
        guard didSetup else { return .unusable("setup never completed") }
        if let failure { close(); return .unusable(failure) }

        commandSink.yield(.endActivity)
        commandSink.finish()

        // Wait for the send loop to actually flush activityEnd before starting
        // the clock on the final transcript.
        let flushDeadline = Date().addingTimeInterval(2.0)
        while !activityEndFlushed, failure == nil, Date() < flushDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if let failure { close(); return .unusable(failure) }
        guard activityEndFlushed else { close(); return .unusable("activityEnd never flushed") }

        // A final may already have arrived. Otherwise wait, briefly.
        let finalDeadline = Date().addingTimeInterval(deadline)
        while finals.isEmpty, failure == nil, Date() < finalDeadline {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        close()

        if let failure { return .unusable(failure) }
        guard !finals.isEmpty else { return .unusable("no final transcript before deadline") }
        if ring.didDrop { return .unusable("dropped \(ring.droppedChunks) chunks — stream is truncated") }

        let joined = finals.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return .unusable("final transcript was empty") }
        return .completed(joined)
    }

    /// Tear down without waiting. Idempotent — every path that abandons a session
    /// calls this, including several that run before `start` ever completed.
    public func abort() {
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        sendLoop?.cancel()
        receiveLoop?.cancel()
        commandSink.finish()
        partialSink.finish()
        transport.close()
    }

    /// Bytes the socket accepted, for reconciliation against `framesWritten * 2`.
    public var acceptedBytes: Int64 { ring.acceptedBytes }
}

public enum LiveError: Error, Equatable {
    case refused(String)
    case setupTimedOut
}
