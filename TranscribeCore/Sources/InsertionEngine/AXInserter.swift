import AppKit
import ApplicationServices
import Foundation

/// Tier 1: direct Accessibility insertion at the cursor — no clipboard involved.
///
/// Verification is mandatory: Electron apps report AX set success without
/// inserting (Electron #36337/#37465). We verify by comparing the element's value
/// before and after — substitution-proof (smart quotes) and lie-proof: if the
/// value didn't change, the insert didn't happen and the ladder falls through.
@MainActor
public enum AXInserter {
    public static func insert(_ text: String, targetPID: pid_t?, bundleID: String?) -> Bool {
        if let bundleID, AppQuirks.forcePaste.contains(bundleID) {
            return false
        }
        if let bundleID, let targetPID, AppQuirks.needsManualAccessibility.contains(bundleID) {
            wakeChromiumAccessibility(pid: targetPID)
        }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        // Never write into secure fields.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == "AXSecureTextField" {
            return false
        }

        // Readable value is the precondition for verification; without it we cannot
        // prove the insert landed, so we fall to paste rather than risk a double.
        guard let before = stringValue(of: element) else { return false }

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard settable.boolValue else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            return false
        }

        let after = stringValue(of: element)
        let landed = after != nil && after != before
        if !landed {
            Log.insertion.info("AXInserter: set reported success but value unchanged — falling to paste")
        }
        return landed
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? String
    }

    /// Chromium builds its a11y tree lazily; AXManualAccessibility asks for it
    /// without the VoiceOver-reserved side effects. First set can take a moment on
    /// big apps — the ladder's fallback covers the not-ready case.
    private static func wakeChromiumAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
