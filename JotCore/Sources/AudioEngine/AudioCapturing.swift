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

/// Result of a completed (or stopped) capture.
public struct AudioCaptureResult: Equatable, Sendable {
    public var framesWritten: Int64
    public var durationSeconds: Double
    /// Seconds-from-start positions where a device change may have left a seam.
    public var gapMarkers: [Double]
    /// Peak metered level (same 0…1 scale as `onLevel`). Distinguishes "held the
    /// key in silence" from "spoke but transcription came back empty" (F9a vs F9b).
    public var peakLevel: Float
    /// The same peak, computed from the bytes actually written to disk rather
    /// than from the tap. Logged alongside `peakLevel` so the two can be compared
    /// on real sessions before anything is gated on the written one.
    public var writtenPeakLevel: Float
    /// False when NOTHING measured this session's loudness — no metered buffer,
    /// no written buffer. Callers must then assume speech and upload: a wasted
    /// round-trip costs a fraction of a cent, a discarded session costs the words.
    public var peakIsTrustworthy: Bool

    public init(
        framesWritten: Int64,
        durationSeconds: Double,
        gapMarkers: [Double] = [],
        peakLevel: Float = 1.0,
        writtenPeakLevel: Float = 1.0,
        peakIsTrustworthy: Bool = true
    ) {
        self.framesWritten = framesWritten
        self.durationSeconds = durationSeconds
        self.gapMarkers = gapMarkers
        self.peakLevel = peakLevel
        self.writtenPeakLevel = writtenPeakLevel
        self.peakIsTrustworthy = peakIsTrustworthy
    }
}

/// Seam for the coordinator so it can be tested headless with a fake recorder.
public protocol AudioCapturing: AnyObject {
    /// ~30Hz RMS level in 0…1, delivered on an arbitrary queue.
    var onLevel: ((Float) -> Void)? { get set }
    /// Fired when the input device changed mid-recording (informational).
    var onDeviceChange: ((String) -> Void)? { get set }
    /// Fired once when disk writes fail persistently (F22) — captured audio up to
    /// that point is preserved; the coordinator should finalize early.
    var onWriteFailure: (() -> Void)? { get set }
    /// Fired once when the engine dies mid-recording and cannot be revived
    /// (rebuild failed, or the reconnect circuit breaker tripped). Captured
    /// audio up to the seam is preserved; the coordinator should finalize with
    /// what exists — a pill that keeps "listening" while nothing records is the
    /// worst kind of word loss. The message describes the cause for the user.
    var onEngineDied: ((String) -> Void)? { get set }
    /// Starts the engine and begins writing CAF to `url` immediately.
    func start(writingTo url: URL) throws
    /// Stops and finalizes the file, first draining the HAL's in-flight buffer
    /// so the tail of the last word is not discarded. Safe to call once.
    func stop() async -> AudioCaptureResult
}
