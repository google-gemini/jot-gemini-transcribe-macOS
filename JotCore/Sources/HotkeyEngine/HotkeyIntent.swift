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

/// What the hotkey layer asks the session coordinator to do.
public enum HotkeyIntent: Equatable, Sendable {
    /// Key went down — start recording NOW (audio from t=0, before classification).
    case begin
    /// Double-tap detected — lock into hands-free recording.
    case lockIn
    /// Hold released (or stop requested while locked) — finalize and transcribe.
    case finalize
    /// Esc — cancel the session (audio still saved per retention policy).
    case cancel
    /// Single short tap with no second tap — cancel quietly and show the
    /// "Hold to talk — double-tap to lock" coaching hint (never an error sound).
    case shortTapHint
    /// Another key was typed within the interruption window — accidental chord,
    /// cancel silently (Wispr/VoiceInk pattern).
    case abortAccidental
}

/// Timing constants for the hotkey grammar (critic reconciliation #1).
public enum HotkeyTuning {
    /// Press shorter than this is a "tap"; at/above is a hold (push-to-talk).
    public static let holdThreshold: TimeInterval = 0.30
    /// Max gap between first tap's key-up and second tap's key-down to count as a
    /// double-tap. Loosened after dogfood (0.35 → 0.5); the gesture is opt-in now —
    /// the timing-free hands-free path is Space-while-holding.
    public static let doubleTapWindow: TimeInterval = 0.50
    /// A non-hotkey keystroke within this window of session start aborts as accidental.
    public static let interruptionWindow: TimeInterval = 1.0
}
