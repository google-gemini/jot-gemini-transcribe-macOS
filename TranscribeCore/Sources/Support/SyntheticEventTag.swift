import Foundation

/// Marker for CGEvents we synthesize ourselves (the InsertionEngine's ⌘V).
/// The event tap filters on this so our own keystrokes never feed the hotkey
/// grammar or trip the accidental-chord guard.
public enum SyntheticEventTag {
    /// "GT" + arbitrary suffix — set via CGEventField.eventSourceUserData.
    public static let magic: Int64 = 0x4754_0001
}
