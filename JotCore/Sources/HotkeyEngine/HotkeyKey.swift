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

import CoreGraphics
import Foundation

/// A bare-modifier dictation key. These are exactly the keys RegisterEventHotKey and
/// Electron's globalShortcut cannot capture — hence the CGEventTap engine.
public enum HotkeyKey: String, CaseIterable, Codable, Sendable {
    case fn
    case rightCommand
    case rightOption
    case rightControl

    /// Virtual keycode carried in the flagsChanged event.
    public var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        }
    }

    /// Whether this key is DOWN per the event's flags. Sided keys use the raw
    /// device-specific bits (NX_DEVICERCMDKEYMASK etc.) — the generic masks stay
    /// set while the opposite-side twin is held, which made us miss releases
    /// (audit L4).
    public func isDown(in flags: CGEventFlags) -> Bool {
        switch self {
        case .fn:
            return flags.contains(.maskSecondaryFn)
        case .rightCommand:
            return flags.rawValue & 0x10 != 0 // NX_DEVICERCMDKEYMASK
        case .rightOption:
            return flags.rawValue & 0x40 != 0 // NX_DEVICERALTKEYMASK
        case .rightControl:
            return flags.rawValue & 0x2000 != 0 // NX_DEVICERCTLKEYMASK
        }
    }

    public var displayName: String {
        switch self {
        case .fn: return "fn 🌐"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        }
    }
}
