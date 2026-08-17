import Foundation

/// Launch-time crash recovery (F14, critic reconciliation #8):
/// the MOST RECENT interrupted session is auto-transcribed (that's the one the
/// user actually lost mid-flow); older interrupted folders become manual
/// "Recovered — Retry" rows. Never auto-insert — the focus context is gone.
@MainActor
public final class RecoveryScanner {
    private let store: HistoryStore
    private let transcription: TranscriptionServicing

    public var onRecovered: ((String) -> Void)?

    public init(store: HistoryStore, transcription: TranscriptionServicing) {
        self.store = store
        self.transcription = transcription
    }

    public func scanAndRecover() async {
        store.reindex()
        let interrupted = store.interruptedRecords()
        guard !interrupted.isEmpty else { return }
        Log.history.info("RecoveryScanner: \(interrupted.count) interrupted session(s) found")

        for (index, record) in interrupted.enumerated() {
            let folder = record.folderURL
            guard var meta = SessionMeta.read(from: folder) else { continue }
            let cafURL = FileLayout.audioCAF(in: folder)
            guard FileManager.default.fileExists(atPath: cafURL.path) else {
                meta.status = .failed
                meta.errorCode = "no_audio_file"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
                continue
            }

            if index == 0 {
                // Auto-transcribe only the most recent (quota-respectful).
                do {
                    // Crashed sessions never wrote a duration — estimate from the
                    // CAF so the network deadline scales properly (audit #7).
                    let duration = meta.audioDurationSeconds
                        ?? FileLayout.estimatedDuration(ofCAF: cafURL)
                        ?? 60
                    let context = DictationContext(
                        targetAppBundleID: meta.targetAppBundleID,
                        targetAppName: meta.targetAppName
                    )
                    let result = try await transcription.transcribe(
                        audioURL: cafURL, durationSeconds: duration, context: context
                    )
                    meta.rawTranscript = result.rawTranscript
                    meta.cleanedTranscript = result.cleanedTranscript
                    meta.modelID = result.modelID
                    meta.status = .awaitingChip // text ready, user decides in History
                    meta.write(to: folder)
                    store.upsert(meta: meta, folder: folder)
                    onRecovered?("Recovered your last dictation — it's in History")
                    Log.history.info("RecoveryScanner: recovered \(record.id, privacy: .public)")
                } catch {
                    meta.status = .queuedForRetry
                    meta.write(to: folder)
                    store.upsert(meta: meta, folder: folder)
                    Log.history.warning("RecoveryScanner: recovery transcription failed — queued (\(error))")
                }
            } else {
                // Older interruptions: keep audio, mark for manual retry.
                meta.status = .queuedForRetry
                meta.errorCode = meta.errorCode ?? "recovered"
                meta.write(to: folder)
                store.upsert(meta: meta, folder: folder)
            }
        }
    }
}
