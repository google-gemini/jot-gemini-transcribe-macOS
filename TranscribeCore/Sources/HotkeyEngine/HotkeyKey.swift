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

    /// The modifier-flag bit whose presence distinguishes key-down from key-up
    /// in a flagsChanged event for this key.
    public var flagMask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightCommand: return .maskCommand
        case .rightOption: return .maskAlternate
        case .rightControl: return .maskControl
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
