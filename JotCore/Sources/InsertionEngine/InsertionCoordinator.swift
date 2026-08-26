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
import Foundation

/// The 3-tier ladder with the two guards that fix Wispr's most-reported bugs:
///
///   guard 1: frontmost app changed since dictation started → NEVER paste blind
///            (text goes to the clipboard; the HUD offers it — F17)
///   guard 2: secure input active → refuse entirely, no clipboard leak (F18)
///
///   tier 1: AX kAXSelectedTextAttribute with read-back verification
///   tier 2: pasteboard + synthesized ⌘V with guarded restore
///   tier 3: text left on the clipboard, visible hint
public struct InsertionCoordinator: TextInserting {
    private let paster: PasteInserter
    /// Injected so a headless test never depends on this machine's UserDefaults.
    private let dictateToClipboard: @MainActor () -> Bool
    private let keepOnClipboard: @MainActor () -> Bool

    @MainActor
    public init(
        dictateToClipboard: @escaping @MainActor () -> Bool = { SettingsStore().dictateToClipboard },
        keepOnClipboard: @escaping @MainActor () -> Bool = { SettingsStore().keepOnClipboard }
    ) {
        self.paster = PasteInserter()
        self.dictateToClipboard = dictateToClipboard
        self.keepOnClipboard = keepOnClipboard
    }

    @MainActor
    public func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        // Guard 2: secure input — the transcript stays in History only.
        if SecureInput.isActive {
            Log.insertion.warning("secure input active at insert time — refusing (text in History only)")
            return .blockedSecureField
        }

        // Read once: a toggle flipped mid-insert must not leave this text placed
        // under one rule and cleaned up under another.
        let keep = keepOnClipboard()

        // Below the secure-input guard on purpose: "put it somewhere I can paste
        // it" must never mean "copy what was typed over a password field".
        if dictateToClipboard() {
            Log.insertion.info("clipboard mode — copying instead of inserting")
            paster.copyOnly(text, archivable: keep)
            return .fellBackToClipboard
        }

        // Guard 1: is the user still where they started dictating?
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let expectedPID = context.targetPID, let frontmost, frontmost.processIdentifier != expectedPID {
            Log.insertion.info("frontmost changed (\(context.targetAppName ?? "?", privacy: .private) → \(frontmost.localizedName ?? "?", privacy: .private)) — no blind paste")
            paster.copyOnly(text, archivable: keep)
            return .frontmostChanged
        }

        // Tier 1: AX direct insertion.
        switch await AXInserter.insert(text, targetPID: context.targetPID, bundleID: context.targetAppBundleID) {
        case .landed:
            Log.insertion.info("inserted via AX")
            // AX writes straight into the element and never touches the
            // pasteboard, so keeping a copy here has to be explicit.
            if keep { paster.copyOnly(text, archivable: true) }
            return .inserted
        case .focusElsewhere:
            // PROVEN focus theft — a blind ⌘V would paste into the thief.
            // Same treatment as the frontmost-changed guard: chip, never blind.
            paster.copyOnly(text, archivable: keep)
            return .frontmostChanged
        case .noEditableTarget:
            // The ⌘V tier would post into the void and return true. "Delivery is
            // best-effort" is honest about a real text field; claiming it when we
            // know there ISN'T one is just wrong.
            paster.copyOnly(text, archivable: keep)
            return .fellBackToClipboard
        case .notPossible:
            break
        }

        // Guard 1 re-check: the AX attempt takes up to ~350ms — a ⌘Tab in that
        // window would land the ⌘V in the wrong app (production pass 2).
        if let expectedPID = context.targetPID,
           let nowFront = NSWorkspace.shared.frontmostApplication,
           nowFront.processIdentifier != expectedPID {
            Log.insertion.info("frontmost changed during AX attempt — no blind paste")
            paster.copyOnly(text, archivable: keep)
            return .frontmostChanged
        }

        // Tier 2: guarded paste. Note: "true" means the ⌘V was POSTED — there is
        // no OS-level delivery receipt for synthetic paste (industry-wide floor;
        // the text also stays recoverable in History).
        if await paster.paste(text, keepingOnClipboard: keep) {
            Log.insertion.info("⌘V posted (delivery is best-effort)")
            return .inserted
        }

        // Tier 3: clipboard floor.
        paster.copyOnly(text, archivable: keep)
        return .fellBackToClipboard
    }
}
