import AppKit
import Foundation

/// Advises on system settings that conflict with using fn/Globe as the dictation key.
///
/// The fn key's short-press action (emoji picker / input switch / macOS Dictation) is
/// handled at the IOHID layer and CANNOT be blocked by an event tap — the only fix is
/// System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing" (research:
/// macos-architecture.md §a).
public enum FnUsageAdvisor {
    public enum GlobeKeyAction: Equatable, Sendable {
        /// Pref missing = OS default behavior (emoji picker on most Macs) — conflict.
        case systemDefault
        case changeInputSource // 1
        case showEmoji // 2
        case startDictation // 3
        case doNothing // 0
        case unknown(Int)

        public var conflictsWithFnHotkey: Bool {
            switch self {
            case .doNothing: return false
            default: return true
            }
        }
    }

    public static func currentGlobeKeyAction() -> GlobeKeyAction {
        guard let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int else {
            return .systemDefault
        }
        switch value {
        case 0: return .doNothing
        case 1: return .changeInputSource
        case 2: return .showEmoji
        case 3: return .startDictation
        default: return .unknown(value)
        }
    }

    /// Deep link to the Keyboard pane where "Press 🌐 key to" lives.
    public static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// Karabiner-Elements' virtual HID driver grabs fn before our tap — warn the user.
    public static func karabinerIsPresent() -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        if apps.contains(where: { $0.bundleIdentifier?.hasPrefix("org.pqrs.Karabiner") == true }) {
            return true
        }
        return FileManager.default.fileExists(atPath: "/Applications/Karabiner-Elements.app")
    }
}
