import Carbon.HIToolbox
import Foundation

/// TN2150: when any app enables secure input (password fields, Terminal's Secure
/// Keyboard Entry), event taps stop seeing keystrokes and dictating into the field
/// would be a credential leak. We refuse politely and never bypass.
public enum SecureInput {
    public static var isActive: Bool {
        IsSecureEventInputEnabled()
    }
}
