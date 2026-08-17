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

    @MainActor
    public init() {
        self.paster = PasteInserter()
    }

    @MainActor
    public func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        // Guard 2: secure input — the transcript stays in History only.
        if SecureInput.isActive {
            Log.insertion.warning("secure input active at insert time — refusing (text in History only)")
            return .blockedSecureField
        }

        // Guard 1: is the user still where they started dictating?
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let expectedPID = context.targetPID, let frontmost, frontmost.processIdentifier != expectedPID {
            Log.insertion.info("frontmost changed (\(context.targetAppName ?? "?", privacy: .public) → \(frontmost.localizedName ?? "?", privacy: .public)) — no blind paste")
            paster.copyOnly(text)
            return .frontmostChanged
        }

        // Tier 1: AX direct insertion.
        if AXInserter.insert(text, targetPID: context.targetPID, bundleID: context.targetAppBundleID) {
            Log.insertion.info("inserted via AX")
            return .inserted
        }

        // Tier 2: guarded paste.
        if await paster.paste(text) {
            Log.insertion.info("inserted via ⌘V paste")
            return .inserted
        }

        // Tier 3: clipboard floor.
        paster.copyOnly(text)
        return .fellBackToClipboard
    }
}
