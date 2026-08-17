import AppKit
import Foundation

/// Transcription seam. M3 provides the Gemini implementation; tests use fakes.
public protocol TranscriptionServicing: Sendable {
    /// Returns (rawTranscript, cleanedTranscript). Throws TranscriptionError.
    func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult
}

public struct TranscriptionResult: Equatable, Sendable {
    public var rawTranscript: String
    public var cleanedTranscript: String
    public var modelID: String

    public init(rawTranscript: String, cleanedTranscript: String, modelID: String) {
        self.rawTranscript = rawTranscript
        self.cleanedTranscript = cleanedTranscript
        self.modelID = modelID
    }
}

public enum TranscriptionError: Error, Equatable, Sendable {
    case offline
    case network(String)
    case auth
    case rateLimitedDaily
    case timeout
    case emptyTranscript
    case safetyBlocked
}

/// Snapshot of where the user was dictating, captured at hotkey-down.
public struct DictationContext: Equatable, Sendable {
    public var targetAppBundleID: String?
    public var targetAppName: String?

    public init(targetAppBundleID: String? = nil, targetAppName: String? = nil) {
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
    }
}

/// Insertion seam. M4 provides the AX/paste ladder; tests use fakes.
public protocol TextInserting {
    @MainActor func insert(_ text: String, context: DictationContext) async -> InsertionOutcome
}

public enum InsertionOutcome: Equatable, Sendable {
    case inserted
    case frontmostChanged
    case fellBackToClipboard
}

// MARK: - M2 stubs (replaced in M3/M4)

/// Until the Gemini client lands, "transcription" echoes a stub instantly.
public struct StubTranscriptionService: TranscriptionServicing {
    public init() {}
    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let text = String(format: "(recorded %.1fs — transcription arrives in M3)", durationSeconds)
        return TranscriptionResult(rawTranscript: text, cleanedTranscript: text, modelID: "stub")
    }
}

/// Until the insertion ladder lands, put the text on the clipboard.
public struct StubClipboardInserter: TextInserting {
    public init() {}
    @MainActor public func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return .fellBackToClipboard
    }
}
