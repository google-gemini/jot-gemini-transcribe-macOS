import Foundation
import Network

/// The offline queue (F1, critic reconciliation #5): drains on network-restored
/// and on launch; one session at a time; drained results NOTIFY and land in
/// History — never auto-insert (focus is long gone). Simple policy: no exponential
/// ladders; the network path monitor IS the retry signal.
@MainActor
public final class RetryQueue {
    private let store: HistoryStore
    private let transcription: TranscriptionServicing
    private let monitor = NWPathMonitor()
    private var draining = false
    private var lastPathSatisfied = false

    public var onDrained: ((Int) -> Void)?

    public init(store: HistoryStore, transcription: TranscriptionServicing) {
        self.store = store
        self.transcription = transcription
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let satisfied = path.status == .satisfied
                let cameOnline = satisfied && !self.lastPathSatisfied
                self.lastPathSatisfied = satisfied
                if cameOnline {
                    Log.history.info("RetryQueue: network restored — draining")
                    await self.drain()
                }
            }
        }
        monitor.start(queue: .main)
        Task { await drain() } // launch drain
    }

    public func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        let retryable = store.retryableRecords()
        guard !retryable.isEmpty else { return }
        var recoveredCount = 0

        for record in retryable {
            switch await process(record) {
            case .recovered:
                recoveredCount += 1
            case .stillOffline:
                Log.history.info("RetryQueue: still offline — pausing drain")
                if recoveredCount > 0 { onDrained?(recoveredCount) }
                return
            case .failed, .skipped:
                continue
            }
        }
        if recoveredCount > 0 {
            onDrained?(recoveredCount)
        }
    }

    /// Manual per-item retry (History context menu) — works on any record.
    /// Shares the draining guard so a manual retry can't double-process a record
    /// the drain is already sending (audit L20).
    public func retrySingle(_ record: DictationRecord) async -> Bool {
        guard !draining else { return false }
        draining = true
        defer { draining = false }
        if case .recovered = await process(record) {
            onDrained?(1)
            return true
        }
        return false
    }

    private enum ProcessResult { case recovered, stillOffline, failed, skipped }

    private func process(_ record: DictationRecord) async -> ProcessResult {
        let folder = record.folderURL
        guard var meta = SessionMeta.read(from: folder) else { return .skipped }
        // Re-read status from disk: a concurrent path may have finished it already.
        if meta.status == .awaitingChip || meta.status == .inserted {
            return .skipped
        }
        let cafURL = FileLayout.audioCAF(in: folder)
        guard FileManager.default.fileExists(atPath: cafURL.path) else {
            meta.status = .failed
            meta.errorCode = "audio_purged"
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .failed
        }
        do {
            let context = DictationContext(
                targetAppBundleID: meta.targetAppBundleID,
                targetAppName: meta.targetAppName
            )
            let result = try await transcription.transcribe(
                audioURL: cafURL,
                durationSeconds: meta.audioDurationSeconds
                    ?? FileLayout.estimatedDuration(ofCAF: cafURL)
                    ?? 60,
                context: context
            )
            meta.rawTranscript = result.rawTranscript
            meta.cleanedTranscript = result.cleanedTranscript
            meta.modelID = result.modelID
            meta.status = .awaitingChip
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .recovered
        } catch let error as TranscriptionError {
            switch error {
            case .offline, .network, .timeout:
                return .stillOffline
            case .badRequest(let message):
                // Permanent (audit #3): mark failed so the queue never spins on it.
                meta.status = .failed
                meta.errorCode = "bad_request"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                Log.history.warning("RetryQueue: permanent failure for \(meta.id, privacy: .public): \(message, privacy: .private)")
                return .failed
            default:
                meta.status = .failed
                meta.errorCode = "retry_\(String(describing: error))"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                return .failed
            }
        } catch {
            // Non-TranscriptionError (e.g. FLAC encode on a corrupt CAF): mark it
            // failed so the queue never spins on it (audit L3).
            Log.history.error("RetryQueue: unexpected error \(error)")
            meta.status = .failed
            meta.errorCode = "retry_unexpected"
            meta.write(to: folder)
            store.upsert(meta: meta, folder: folder)
            return .failed
        }
    }
}
