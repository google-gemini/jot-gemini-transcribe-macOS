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
    public enum Result {
        case landed
        /// AX couldn't do it here — the paste tier is still appropriate.
        case notPossible
        /// PROVEN focus theft: the focused element belongs to a different app.
        /// A blind ⌘V would paste the transcript into the thief.
        case focusElsewhere
        /// PROVEN inert target: focus sits on a control that cannot hold text.
        /// ⌘V would post into the void and the ladder would report success for
        /// text that landed nowhere.
        case noEditableTarget
    }

    enum TargetVerdict: Equatable {
        case editable
        /// Can't tell from AX. The DEFAULT, deliberately: every app whose AX tree
        /// lies (the Electron family) must keep reaching ⌘V as it does today.
        case unknown
        case noEditableTarget
    }

    /// Leaf controls that cannot hold text. Containers (AXGroup, AXScrollArea,
    /// AXWebArea, AXUnknown) are excluded on purpose — a contenteditable or a
    /// lying Electron wrapper reports one while still accepting a paste, and
    /// being wrong here costs a real insertion.
    nonisolated static let inertRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
        "AXMenuItem", "AXMenuBarItem", "AXMenuButton",
        "AXImage", "AXSlider", "AXProgressIndicator", "AXValueIndicator",
        "AXStaticText", "AXToolbar", "AXTabGroup", "AXDisclosureTriangle",
        "AXColorWell", "AXStepper", "AXIncrementor",
    ]

    /// `nonisolated` so it is testable headlessly — the live AX tree is the one
    /// thing a unit test cannot stand up.
    ///
    /// `settable` outranks role: a settable kAXSelectedTextAttribute IS somewhere
    /// text can go, whatever the element calls itself. A readable value with an
    /// unsettable selection is an editor we just can't drive — paste may work.
    nonisolated static func classifyTarget(role: String?, settable: Bool, hasStringValue: Bool) -> TargetVerdict {
        if settable { return .editable }
        guard let role, !hasStringValue else { return .unknown }
        return inertRoles.contains(role) ? .noEditableTarget : .unknown
    }

    public static func insert(_ text: String, targetPID: pid_t?, bundleID: String?) async -> Result {
        if let bundleID, AppQuirks.forcePaste.contains(bundleID) {
            return .notPossible
        }
        // The Chromium a11y wake now happens at session START (AccessibilityWaker),
        // so it never blocks the user's wait for their words.
        let system = AXUIElementCreateSystemWide()
        // A hung target would park this @MainActor call until the system default
        // messaging timeout (seconds), stalling the pill, the status item and the
        // hotkey intent stream behind it. Bound it — a target that can't answer
        // in 1.5s is demoted to the paste tier instead of freezing the app.
        // Deliberately generous: a premature timeout on the SET below would fall
        // through to ⌘V and DOUBLE-INSERT (audit #9).
        AXUIElementSetMessagingTimeout(system, 1.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .notPossible
        }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        // The system-wide focused element must belong to the app the user was
        // dictating into — not whatever stole focus a frame ago (audit L24).
        if let targetPID {
            var elementPID: pid_t = 0
            if AXUIElementGetPid(element, &elementPID) == .success, elementPID != targetPID {
                Log.insertion.info("AXInserter: focused element belongs to a different app — chip, never blind paste")
                return .focusElsewhere
            }
        }

        var roleRef: CFTypeRef?
        let role: String? = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
            ? roleRef as? String
            : nil
        // Never write into secure fields — and never divert one to the clipboard
        // either, so this stays ahead of the target check below (F18).
        if role == "AXSecureTextField" {
            return .notPossible
        }

        let before = stringValue(of: element)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)

        if case .noEditableTarget = classifyTarget(role: role, settable: settable.boolValue, hasStringValue: before != nil) {
            Log.insertion.info("focus is an inert \(role ?? "?", privacy: .public) — clipboard instead of a blind ⌘V")
            return .noEditableTarget
        }

        // Readable value is the precondition for verification; without it we cannot
        // prove the insert landed, so we fall to paste rather than risk a double.
        guard let before else { return .notPossible }
        guard settable.boolValue else { return .notPossible }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success else {
            return .notPossible
        }

        var after = stringValue(of: element)
        var landed = after != nil && after != before
        if !landed {
            // Some apps (web content, async editors) update the AX value a beat
            // late; re-check before falling to paste — a false negative here
            // would DOUBLE-insert (AX landed + ⌘V lands again; audit #9). Poll
            // rather than sleep the full budget: most apps answer on the first
            // step, and only the slow ones pay the rest.
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                after = stringValue(of: element)
                landed = after != nil && after != before
                if landed { break }
            }
        }
        if !landed {
            Log.insertion.info("AXInserter: set reported success but value unchanged after re-check — falling to paste")
        }
        return landed ? .landed : .notPossible
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
}
