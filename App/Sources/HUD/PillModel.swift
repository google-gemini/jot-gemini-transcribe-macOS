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

import SwiftUI

/// The pill's semantic state — a pure projection of coordinator state
/// (experience spec owns all timing/lifecycle; critic reconciliation #7).
enum PillState: Equatable {
    case hidden
    case idleDot
    case listening(locked: Bool)
    case processing
    case success(words: Int?)
    /// Neutral informational chip (coaching hint, copied-to-clipboard, offline…).
    case notice(String)
    /// Error styling: errorContainer surface + "saved to History" framing.
    case error(String)
}

@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .idleDot
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    /// Still-working slow state (>3s in processing — TimeoutPolicy.slowStateUI).
    @Published var slow = false
    /// Live mode's speculative transcript, shown while the user speaks. Display
    /// only: this is a guess the model is still revising, and it is never what
    /// gets inserted.
    @Published var partial: String = ""
    /// Changes once per dictation, when the finished transcript replaces the
    /// running guess. Drives the Gemini sweep.
    @Published var corrected: String = ""
}
