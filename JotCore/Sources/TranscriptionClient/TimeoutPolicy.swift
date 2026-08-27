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

/// The single source of truth for every network deadline in the app.
/// (Critic reconciliation #9 — no other file may define timeout constants.)
public enum TimeoutPolicy {
    /// TCP+TLS connect budget before the attempt is abandoned.
    /// How long to wait after activityEnd for the server's final transcript.
    /// Generous because the alternative is not an error, it is re-uploading audio
    /// we already streamed — but bounded, because the user is staring at a pill.
    public static let liveFinal: TimeInterval = 6

    public static let connect: TimeInterval = 5
    /// Time to the first SSE byte after the request body is sent.
    public static let timeToFirstByte: TimeInterval = 10
    /// Max gap between SSE chunks once streaming has begun.
    public static let interChunkStall: TimeInterval = 10
    /// When the HUD flips to the "Still working…" slow state.
    public static let slowStateUI: TimeInterval = 3

    /// Overall per-request deadline. Scales gently with audio length:
    /// 5s clip → 31s; 10min clip → 2.5min. Never the unbounded 2×duration formula.
    public static func overallDeadline(audioDuration: TimeInterval) -> TimeInterval {
        30 + audioDuration / 4
    }
}
