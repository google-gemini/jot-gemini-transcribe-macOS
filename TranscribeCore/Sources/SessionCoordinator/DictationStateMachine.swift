import Foundation

/// Why a dictation session ended unsuccessfully. Copy for each case lives with the
/// failure matrix (docs/design/product-reliability.md, F1–F24).
public enum DictationFailure: Equatable, Sendable {
    /// Audio engine failed to start or died.
    case audio
    /// Zero buffers captured (engine race, F21) — never shown as an empty transcript.
    case noAudio
    /// Transport-level failure after the silent retry (F1/F2/F6/F7/F8).
    case network
    /// 401/403 — key invalid, revoked, or restricted (F4/F19).
    case auth
    /// 429 with a hard (daily) quota (F5).
    case quotaExhausted
    /// Deadline exceeded per TimeoutPolicy (F7).
    case timeout
    /// Validation gate failed even after the verbatim retry (F9a/F10).
    case validation
    /// API refused via safety block after verbatim retry (F12).
    case safetyBlocked
    /// Disk write failure (F22).
    case storage
}

/// Terminal outcome of a successful-enough session.
public enum DictationOutcome: Equatable, Sendable {
    /// Text landed at the cursor via the insertion ladder.
    case inserted
    /// Focus changed mid-flight; user was offered a chip instead of a blind paste (F17).
    case awaitingChip
    /// Ladder exhausted; text left on the clipboard with a visible hint (F16).
    case copiedToClipboard
    /// Secure input was active at insert time — text lives in History only (F18).
    case heldForSecureField
    /// Offline or transient failure; recording queued for auto-retry (F1).
    case queuedForRetry
    /// Silence-only audio (F9b) — kept in History, no error theatrics.
    case silent
}

/// A single dictation session's lifecycle. The coordinator may run several sessions
/// concurrently (one recording + N in flight); each session steps through this
/// machine independently, keyed by its UUID.
public enum DictationState: Equatable, Sendable {
    case idle
    /// Hotkey went down: session folder created, audio engine starting, connection pre-warming.
    case warming
    case recording(locked: Bool)
    /// Key released / stop pressed: engine stopping, CAF flushed, FLAC encoding.
    case finalizing
    case transcribing
    case inserting
    case done(DictationOutcome)
    case cancelled
    case failed(DictationFailure)

    public var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .failed: return true
        default: return false
        }
    }
}

public enum DictationEvent: Equatable, Sendable {
    // Hotkey intents
    case hotkeyBegin
    case lockIn
    case finalize
    case cancel
    /// A non-modifier key was typed within the interruption window — accidental chord.
    case abortAccidental

    // Audio
    case engineStarted
    case engineFailed
    case audioFinalized
    case noAudioCaptured
    case silenceOnly

    // Transcription
    case transcriptReady
    case transcriptFailed(DictationFailure)
    case queuedForRetry

    // Insertion
    case inserted
    case insertionFellBackToClipboard
    case frontmostChangedAwaitingChip
    case insertionBlockedSecure
}

/// Pure transition function — the only place session-lifecycle rules live.
/// Returns `nil` for events that are invalid/ignored in the given state (stale
/// completions, double events); callers log-and-drop those.
public enum DictationStateMachine {
    public static func transition(_ state: DictationState, on event: DictationEvent) -> DictationState? {
        switch (state, event) {
        // idle → warming
        case (.idle, .hotkeyBegin):
            return .warming

        // warming
        case (.warming, .engineStarted):
            return .recording(locked: false)
        case (.warming, .engineFailed):
            return .failed(.audio)
        case (.warming, .cancel), (.warming, .abortAccidental):
            return .cancelled
        // Key released before the engine even reported started: still a real dictation —
        // finalize with whatever was captured (prewarm means audio runs from t=0).
        case (.warming, .finalize):
            return .finalizing

        // recording
        case (.recording(locked: false), .lockIn):
            return .recording(locked: true)
        case (.recording, .finalize):
            return .finalizing
        case (.recording, .cancel), (.recording, .abortAccidental):
            return .cancelled
        case (.recording, .engineFailed):
            // Mid-recording engine death: whatever hit the CAF is preserved; finalize path
            // decides between transcribing the partial audio and surfacing the error.
            return .finalizing

        // finalizing
        case (.finalizing, .audioFinalized):
            return .transcribing
        case (.finalizing, .noAudioCaptured):
            return .failed(.noAudio)
        case (.finalizing, .silenceOnly):
            return .done(.silent)
        case (.finalizing, .cancel):
            return .cancelled

        // transcribing
        case (.transcribing, .transcriptReady):
            return .inserting
        case (.transcribing, .transcriptFailed(let failure)):
            return .failed(failure)
        case (.transcribing, .queuedForRetry):
            return .done(.queuedForRetry)
        case (.transcribing, .cancel):
            return .cancelled

        // inserting — no cancel here: the text exists, History has it regardless.
        case (.inserting, .inserted):
            return .done(.inserted)
        case (.inserting, .insertionFellBackToClipboard):
            return .done(.copiedToClipboard)
        case (.inserting, .frontmostChangedAwaitingChip):
            return .done(.awaitingChip)
        case (.inserting, .insertionBlockedSecure):
            return .done(.heldForSecureField)

        default:
            return nil
        }
    }
}
