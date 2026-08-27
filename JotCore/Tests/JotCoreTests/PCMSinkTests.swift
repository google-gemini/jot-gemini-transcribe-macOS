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

import AVFoundation
import XCTest
@testable import JotCore

/// The byte arithmetic the live path's safety net is built on.
///
/// A live stream may only be promoted to the session's real transcript when the
/// bytes the socket accepted equal `framesWritten * 2`. That identity is the only
/// mechanical way to tell a complete stream from a truncated one — the text
/// itself cannot say, because a transcript missing its opening three seconds
/// reads perfectly. Get it wrong and a partial transcript is written to
/// `rawTranscript`, at which point `RetryQueue` and `RecoveryScanner` both treat
/// the row as already recovered and never re-transcribe, and under "Never keep
/// audio" the recording is deleted behind it. Words gone, History showing success.
///
/// Hence a test rather than a comment.
final class PCMSinkTests: XCTestCase {

    /// 16kHz mono Int16 interleaved — the format the engine converts to and
    /// exactly what the Live API's WebSocket expects.
    private func makeFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }

    private func makeBuffer(frames: AVAudioFrameCount, fill: Int16 = 0) -> AVAudioPCMBuffer {
        let format = makeFormat()
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.int16ChannelData {
            for index in 0..<Int(frames) { channel[0][index] = fill }
        }
        return buffer
    }

    /// The load-bearing identity: two bytes per frame, exactly.
    func testByteCountIsExactlyTwoPerFrame() throws {
        for frames in [AVAudioFrameCount(1), 160, 1024, 1664, 2048, 8000] {
            let bytes = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: frames)))
            XCTAssertEqual(bytes.count, Int(frames) * 2,
                           "\(frames) frames must be \(Int(frames) * 2) bytes — the promotion check compares against framesWritten * 2")
        }
    }

    /// Summing chunk byte counts must equal total frames * 2. This is the actual
    /// reconciliation the live session performs at the end of a dictation, and the
    /// tap delivers variable-length buffers, so it must hold across ragged sizes.
    func testAccumulatedBytesReconcileWithTotalFrames() throws {
        // Deliberately ragged: converter output length varies, and the OS clamps
        // the tap to whatever it likes regardless of the bufferSize we request.
        let sizes: [AVAudioFrameCount] = [1664, 1664, 1600, 1664, 1728, 933]
        var accumulated = 0
        var totalFrames: Int64 = 0
        for frames in sizes {
            let bytes = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: frames)))
            accumulated += bytes.count
            totalFrames += Int64(frames)
        }
        XCTAssertEqual(Int64(accumulated), totalFrames * 2,
                       "a stream that dropped nothing must reconcile exactly")
    }

    /// A dropped chunk must make the identity FAIL. If this ever passes, the
    /// truncation check is decorative and the fallback never fires.
    func testDroppedChunkBreaksReconciliation() throws {
        let sizes: [AVAudioFrameCount] = [1664, 1664, 1600, 1664]
        var accumulated = 0
        var totalFrames: Int64 = 0
        for (index, frames) in sizes.enumerated() {
            let bytes = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: frames)))
            totalFrames += Int64(frames)
            if index == 1 { continue }  // the socket stalled; the ring dropped this one
            accumulated += bytes.count
        }
        XCTAssertNotEqual(Int64(accumulated), totalFrames * 2,
                          "a dropped chunk MUST be detectable — this is the whole truncation guard")
    }

    /// Content must survive the round trip: a silent chunk and a loud chunk are
    /// different bytes. Guards against a version that reports a plausible length
    /// while emitting zeros.
    func testBytesCarryTheSamplesNotJustTheLength() throws {
        let quiet = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: 64, fill: 0)))
        let loud = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: 64, fill: 12_000)))
        XCTAssertEqual(quiet.count, loud.count)
        XCTAssertNotEqual(quiet, loud, "the sink must carry samples, not just a byte count")
        XCTAssertTrue(quiet.allSatisfy { $0 == 0 })
    }

    /// Little-endian, because that is what the API is promised: 12_000 = 0x2EE0,
    /// so the low byte comes first on every Apple silicon and Intel Mac.
    func testSamplesAreLittleEndian() throws {
        let bytes = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: 2, fill: 12_000)))
        XCTAssertEqual([UInt8](bytes), [0xE0, 0x2E, 0xE0, 0x2E])
    }

    /// An empty buffer is zero bytes, not nil. It still reconciles (0 == 0 * 2),
    /// so it must not be confused with the unreadable-format case.
    func testEmptyBufferIsZeroBytesNotNil() throws {
        let bytes = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: 0)))
        XCTAssertEqual(bytes.count, 0)
    }

    /// A format the sink cannot read returns nil rather than empty Data —
    /// empty would silently satisfy the reconciliation check.
    func testNonInt16BufferReturnsNil() throws {
        let float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: float, frameCapacity: 128)!
        buffer.frameLength = 128
        XCTAssertNil(AudioCaptureEngine.pcmBytes(from: buffer),
                     "a non-Int16 buffer must be nil, never empty Data")
    }

    /// One second of speech is 32,000 bytes, matching the rate FileLayout already
    /// uses to estimate duration. Cheap cross-check that the format has not drifted.
    func testOneSecondIs32KB() throws {
        let bytes = try XCTUnwrap(AudioCaptureEngine.pcmBytes(from: makeBuffer(frames: 16_000)))
        XCTAssertEqual(bytes.count, 32_000)
    }
}
