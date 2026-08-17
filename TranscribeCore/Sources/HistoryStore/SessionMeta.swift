import Foundation

/// Per-dictation metadata, persisted as meta.json in the session folder.
/// Written at every status transition so crash recovery (M6 RecoveryScanner) can
/// tell exactly how far a session got. Terminal-status writes are the source of
/// truth for "was anything lost?"
public struct SessionMeta: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        /// Audio finalized on disk; transcription not yet complete.
        case recorded
        case transcribing
        case inserted
        case copiedToClipboard
        case awaitingChip
        case heldSecure
        case queuedForRetry
        case silent
        case cancelled
        case failed
    }

    public var id: UUID
    public var startedAt: Date
    public var status: Status
    public var targetAppBundleID: String?
    public var targetAppName: String?
    public var audioDurationSeconds: Double?
    /// Device-change gap markers: seconds-from-start where audio may have a seam.
    public var gapMarkers: [Double]
    public var rawTranscript: String?
    public var cleanedTranscript: String?
    public var errorCode: String?
    public var modelID: String?
    /// Key-up → terminal-state latency, for the local stats overlay.
    public var pipelineSeconds: Double?

    public init(id: UUID, startedAt: Date, status: Status) {
        self.id = id
        self.startedAt = startedAt
        self.status = status
        self.gapMarkers = []
    }

    // MARK: - Disk I/O (atomic)

    public func write(to folder: URL) {
        let url = FileLayout.metaJSON(in: folder)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.history.error("SessionMeta: write failed for \(self.id, privacy: .public): \(error)")
        }
    }

    public static func read(from folder: URL) -> SessionMeta? {
        let url = FileLayout.metaJSON(in: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMeta.self, from: data)
    }
}
