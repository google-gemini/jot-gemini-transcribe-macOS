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

/// The buffer between the audio write queue and the WebSocket.
///
/// It exists because those two run at different speeds and only one of them is
/// allowed to be slow. The write queue owns conversion, the CAF file handle, the
/// frame counter, and the waiter `stop()` parks on — if the socket ever
/// back-pressured it, dictation would not merely lag, finalization would hang.
/// So the socket is never allowed to push back: when it stalls, audio is dropped
/// from the *network* stream and never from the file.
///
/// **It is the only buffer.** An earlier design had this ring plus an unbounded
/// `AsyncStream` of chunks, which is worse than either alone: whichever one is
/// actually bounded becomes the real drop policy, and if that is the stream the
/// drops happen with no counter and no hook. The stream now carries `Void`
/// wakeups; every byte lives here, where dropping is counted.
///
/// Counting is the point. A dropped chunk means the transcript the server
/// returns is missing words, and no amount of reading it will reveal that — a
/// transcript missing its opening three seconds is perfectly fluent. The live
/// path may only replace the real transcript when `acceptedBytes` reconciles
/// against the frames written to disk, and this type is what makes that
/// checkable.
public final class PCMRing: @unchecked Sendable {

    /// 16kHz mono Int16 = 32,000 bytes per second of audio.
    public static let bytesPerSecond = 32_000

    private let capacityBytes: Int
    private var chunks: [Data] = []
    private var queuedBytes = 0
    private var accepted: Int64 = 0
    private var dropped: Int64 = 0
    private var droppedChunkCount = 0
    private let lock = NSLock()

    /// - Parameter seconds: how much audio may sit unsent before the oldest is
    ///   dropped. Must comfortably exceed connect time + setup handshake + a
    ///   couple of chunk periods, or a slow handshake alone will eat the opening
    ///   words of every dictation — which is exactly the failure the reconciliation
    ///   check is there to catch, so sizing this too small means falling back to
    ///   the batch path constantly rather than losing words.
    public init(seconds: Double = 8.0) {
        self.capacityBytes = max(Self.bytesPerSecond, Int(seconds * Double(Self.bytesPerSecond)))
    }

    /// Called from the audio write queue. Never blocks, never awaits.
    ///
    /// Drop-oldest rather than drop-newest: the newest audio is the audio the
    /// user is still speaking, and the server needs a contiguous recent stream
    /// more than it needs a stale prefix. Either way the session is disqualified
    /// from promotion — this only decides which words the server sees before we
    /// fall back.
    public func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        chunks.append(chunk)
        queuedBytes += chunk.count
        while queuedBytes > capacityBytes, !chunks.isEmpty {
            let evicted = chunks.removeFirst()
            queuedBytes -= evicted.count
            dropped += Int64(evicted.count)
            droppedChunkCount += 1
        }
    }

    /// Everything waiting, in order, leaving the ring empty. The send loop calls
    /// this; bytes are counted as accepted only once they have actually been
    /// handed to the socket, which is why `markAccepted` is separate.
    public func drain() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let out = chunks
        chunks.removeAll(keepingCapacity: true)
        queuedBytes = 0
        return out
    }

    /// Recorded after `send` returns without throwing. Kept separate from
    /// `drain` so a chunk that failed mid-send is not counted as delivered —
    /// counting on drain would make a failed send look like a complete stream.
    public func markAccepted(_ byteCount: Int) {
        lock.lock()
        accepted += Int64(byteCount)
        lock.unlock()
    }

    /// Bytes the socket has actually taken. Compared against `framesWritten * 2`
    /// to decide whether the live transcript may be trusted.
    public var acceptedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return accepted
    }

    public var droppedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    /// Non-zero means the transcript is missing audio. On its own this is enough
    /// to disqualify a session from promotion, without waiting for the byte
    /// reconciliation to notice.
    public var didDrop: Bool {
        lock.lock(); defer { lock.unlock() }
        return dropped > 0
    }

    public var droppedChunks: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedChunkCount
    }

    public var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedBytes
    }

    /// Human-readable, for the log line written at the end of every live session.
    public var summary: String {
        lock.lock(); defer { lock.unlock() }
        let seconds = Double(dropped) / Double(Self.bytesPerSecond)
        return "accepted=\(accepted)B dropped=\(dropped)B (\(String(format: "%.2f", seconds))s, \(droppedChunkCount) chunks)"
    }
}
