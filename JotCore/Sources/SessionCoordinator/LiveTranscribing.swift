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

/// The coordinator's view of a live session.
///
/// A separate seam from `TranscriptionServicing` on purpose. That protocol's
/// other callers — `RetryQueue` and `RecoveryScanner` — read a CAF off disk long
/// after the session ended, and they are the never-lose-words safety net.
/// Widening it with streaming concepts would drag a socket into the two places
/// whose entire job is to work when everything else has already failed.
///
/// `finish` returns an optional, and that shape is the whole contract: the
/// coordinator does not inspect, score, or repair a live result. It either gets
/// a transcript it may use, or it gets nil and uploads the file exactly as it
/// always has.
public protocol LiveTranscribing: AnyObject, Sendable {
    /// Opens the socket and handshakes. Throwing is normal and cheap — the
    /// caller falls back to batch and the user never learns a socket existed.
    func begin() async throws

    /// Called from the audio write queue for every converted buffer.
    /// **Must not block and must not await** — that queue owns the CAF file
    /// handle and the waiter `stop()` parks on.
    nonisolated func enqueue(_ pcm: Data)

    /// Ends the turn and returns a usable transcript, or nil.
    ///
    /// `framesWritten` is the count the audio engine actually wrote to disk, and
    /// it is the reconciliation input: a stream may only be trusted when the
    /// bytes the socket accepted equal `framesWritten * 2`. Text alone cannot
    /// reveal truncation — a transcript missing its opening seconds reads
    /// perfectly — so the check is arithmetic, not judgement.
    func finish(deadline: TimeInterval, framesWritten: Int64) async -> TranscriptionResult?

    /// Tear down without waiting. Idempotent; called from every path that
    /// abandons a session, including several that run before `begin` finished.
    func abort() async
}

/// Wraps a `LiveTranscriptionSession` and turns a clean stream into the same
/// `TranscriptionResult` the batch path produces.
public final class LiveTranscriber: LiveTranscribing, @unchecked Sendable {

    private let session: LiveTranscriptionSession
    private let replacementRules: @Sendable () -> [ReplacementEngine.Rule]
    private let modelID: String

    public init(session: LiveTranscriptionSession,
                modelID: String,
                replacementRules: @escaping @Sendable () -> [ReplacementEngine.Rule]) {
        self.session = session
        self.modelID = modelID
        self.replacementRules = replacementRules
    }

    /// Partials for the HUD. Nothing here may become the transcript.
    public var partials: AsyncStream<String> { session.partials }

    public func begin() async throws {
        try await session.start()
    }

    public nonisolated func enqueue(_ pcm: Data) {
        session.enqueue(pcm)
    }

    public func finish(deadline: TimeInterval, framesWritten: Int64) async -> TranscriptionResult? {
        let outcome = await session.finish(deadline: deadline)
        guard case .completed(let text) = outcome else {
            if case .unusable(let why) = outcome {
                Log.transcription.info("live session unusable, falling back to upload: \(why, privacy: .public)")
            }
            return nil
        }

        // The reconciliation. Everything else about a live session can look
        // healthy while audio went missing — this is the only check that sees it.
        let expected = framesWritten * 2
        let accepted = await session.acceptedBytes
        guard accepted == expected else {
            Log.transcription.info(
                "live byte mismatch: socket took \(accepted) of \(expected) — treating as truncated, uploading instead"
            )
            return nil
        }

        // Dictionary corrections run once over the whole transcript, never per
        // chunk: rules are sorted longest-wrong-form-first with word-boundary
        // lookarounds, so a multi-word rule split across a chunk boundary would
        // never fire and the trailing lookahead would misfire at a chunk edge.
        let corrected = ReplacementEngine.apply(replacementRules(), to: text)
        return TranscriptionResult(rawTranscript: text, cleanedTranscript: corrected, modelID: modelID)
    }

    public func abort() async {
        await session.abort()
    }
}
