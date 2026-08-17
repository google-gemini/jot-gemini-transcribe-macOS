import Foundation

/// Audio retention (the setting Superwhisper lacks): purge audio files after N
/// days while KEEPING transcripts + meta forever (until the user deletes them).
/// Audio is never deleted before a transcript exists — that would break Retry.
public struct RetentionPolicy: Sendable {
    public var audioRetentionDays: Int

    public init(audioRetentionDays: Int = SettingsStore().audioRetentionDays) {
        self.audioRetentionDays = audioRetentionDays
    }

    public func purgeExpiredAudio(recordingsRoot: URL = FileLayout.recordingsRoot, now: Date = Date()) {
        guard audioRetentionDays > 0 else { return } // 0 = keep forever
        let cutoff = now.addingTimeInterval(-Double(audioRetentionDays) * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: nil
        )) ?? []
        var purged = 0
        for folder in folders where folder.hasDirectoryPath {
            guard let meta = SessionMeta.read(from: folder),
                  meta.startedAt < cutoff,
                  meta.rawTranscript != nil || meta.status == .cancelled || meta.status == .silent
            else { continue }
            for audio in [FileLayout.audioCAF(in: folder), FileLayout.audioFLAC(in: folder)] {
                if FileManager.default.fileExists(atPath: audio.path) {
                    try? FileManager.default.removeItem(at: audio)
                    purged += 1
                }
            }
        }
        if purged > 0 {
            Log.history.info("RetentionPolicy: purged \(purged) audio file(s) older than \(self.audioRetentionDays)d")
        }
    }
}
