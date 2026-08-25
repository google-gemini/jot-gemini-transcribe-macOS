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

/// Marker for CGEvents we synthesize ourselves (the InsertionEngine's ⌘V).
/// The event tap filters on this so our own keystrokes never feed the hotkey
/// grammar or trip the accidental-chord guard.
public enum SyntheticEventTag {
    /// "JotUI" + arbitrary suffix — set via CGEventField.eventSourceUserData.
    public static let magic: Int64 = 0x4A4F_0001
}
