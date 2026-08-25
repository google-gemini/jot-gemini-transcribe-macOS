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

/// Measures how loud the room is, so "did they speak?" can be asked relative to
/// the room instead of against a constant that assumes a quiet one.
///
/// Jot's absolute thresholds are `0.06` ≈ −58 dBFS and `0.08` ≈ −55 dBFS. Any
/// occupied room clears both, which is why noise doesn't merely degrade accuracy
/// — it makes the trailing-capture loop run to its full cap on every dictation
/// and turns "nobody spoke" into a hard failure.
///
/// **This type always runs, and it decides nothing.** It observes the level
/// stream and records numbers into `SessionMeta`; whether anything acts on them
/// is the caller's business, gated behind `experimentalNoiseHandling`. Ships
/// unflagged precisely so the calibration data accumulates before the behaviour
/// that depends on it does.
public struct NoiseFloorEstimator: Sendable {
    /// Below this many samples the percentile is meaningless — with tap buffers
    /// arriving at ~10 Hz this is ~0.8s of audio.
    public static let minimumSamples = 8
    /// The floor is the quietest tenth of the session, not the minimum: a single
    /// anomalous buffer shouldn't define the room.
    public static let percentile = 0.10

    /// ~60s at the real ~10 Hz tap rate. The recording cap is 10 minutes, and a
    /// floor from nine minutes ago is not this room any more.
    private let capacity: Int
    private var samples: [Double] = []

    public private(set) var peakDB: Double = AudioLevelCurve.floorDBFS
    public private(set) var sampleCount: Int = 0

    public init(capacity: Int = 600) {
        self.capacity = max(Self.minimumSamples, capacity)
        samples.reserveCapacity(self.capacity)
    }

    public mutating func ingest(level: Float) {
        let db = AudioLevelCurve.dBFS(fromLevel: level)
        peakDB = max(peakDB, db)
        sampleCount += 1
        if samples.count == capacity { samples.removeFirst() }
        samples.append(db)
    }

    /// The room, in dBFS — the 10th percentile of everything heard so far.
    ///
    /// A rolling low percentile rather than "the first N milliseconds": prewarm
    /// means audio starts the instant the key goes down, which is exactly when a
    /// fast user is *already speaking*, so treating the head as noise would
    /// classify speech as the floor and make every downstream decision worse.
    /// Speech is intermittent — there are gaps between words and phrases — so the
    /// percentile converges on the floor within a second or two even when speech
    /// starts at sample 0, and it tracks a floor that rises mid-session.
    public var floorDB: Double? {
        guard samples.count >= Self.minimumSamples else { return nil }
        let sorted = samples.sorted()
        let index = Int((Double(sorted.count - 1) * Self.percentile).rounded())
        return sorted[index]
    }

    /// Peak minus floor. A **lower bound** on the true SNR: the level curve
    /// saturates at −20.8 dBFS, so loud speech understates its own peak. Biasing
    /// low means we conclude "noisy" more readily than "clean", and every
    /// consequence of "noisy" in this codebase keeps audio rather than dropping it.
    public var measuredSNR: Double? {
        guard let floorDB else { return nil }
        return peakDB - floorDB
    }
}
