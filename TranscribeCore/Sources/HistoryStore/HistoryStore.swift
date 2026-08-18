import Foundation
import GRDB

/// Queryable index over the session folders (which remain the source of truth —
/// meta.json per folder). The DB makes History fast to search and stats cheap.
public struct DictationRecord: Codable, Equatable, Identifiable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "dictation"

    public var id: String
    public var folder: String
    public var startedAt: Date
    public var status: String
    public var targetAppName: String?
    public var targetAppBundleID: String?
    public var durationSeconds: Double?
    public var rawTranscript: String?
    public var cleanedTranscript: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var pipelineSeconds: Double?

    public var displayText: String {
        cleanedTranscript ?? rawTranscript ?? ""
    }

    public var folderURL: URL {
        URL(fileURLWithPath: folder, isDirectory: true)
    }

    public init(meta: SessionMeta, folder: URL) {
        self.id = meta.id.uuidString
        self.folder = folder.path
        self.startedAt = meta.startedAt
        self.status = meta.status.rawValue
        self.targetAppName = meta.targetAppName
        self.targetAppBundleID = meta.targetAppBundleID
        self.durationSeconds = meta.audioDurationSeconds
        self.rawTranscript = meta.rawTranscript
        self.cleanedTranscript = meta.cleanedTranscript
        self.errorCode = meta.errorCode
        self.errorMessage = meta.errorMessage
        self.pipelineSeconds = meta.pipelineSeconds
    }
}

public extension Notification.Name {
    /// Posted after any HistoryStore write so an open History pane refreshes as
    /// dictations land, retries drain, or rows are deleted — no polling.
    static let gtHistoryDidChange = Notification.Name("com.google.transcribe.history-changed")
}

public final class HistoryStore: @unchecked Sendable {
    private let queue: DatabaseQueue

    private static func notifyChanged() {
        NotificationCenter.default.post(name: .gtHistoryDidChange, object: nil)
    }

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        queue = try Self.openOrRecreate(at: databaseURL)
        try migrate()
    }

    /// A corrupt index must not disable history/recovery forever — the folders
    /// are the source of truth, so quarantine and rebuild (audit L6).
    private static func openOrRecreate(at databaseURL: URL) throws -> DatabaseQueue {
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            // Probe readability so corruption surfaces here, not at first query.
            _ = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA schema_version") }
            return queue
        } catch {
            Log.history.error("HistoryStore: open failed (\(error)) — quarantining and recreating index")
            let quarantine = databaseURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).sqlite")
            try? FileManager.default.moveItem(at: databaseURL, to: quarantine)
            return try DatabaseQueue(path: databaseURL.path)
        }
    }

    public static func standard() throws -> HistoryStore {
        try HistoryStore(databaseURL: FileLayout.appSupportRoot.appendingPathComponent("history.sqlite"))
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: DictationRecord.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("folder", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("status", .text).notNull().indexed()
                t.column("targetAppName", .text)
                t.column("targetAppBundleID", .text)
                t.column("durationSeconds", .double)
                t.column("rawTranscript", .text)
                t.column("cleanedTranscript", .text)
                t.column("errorCode", .text)
                t.column("pipelineSeconds", .double)
            }
        }
        migrator.registerMigration("v2-errorMessage") { db in
            try db.alter(table: DictationRecord.databaseTableName) { t in
                t.add(column: "errorMessage", .text)
            }
        }
        try migrator.migrate(queue)
    }

    // MARK: - Writes

    public func upsert(meta: SessionMeta, folder: URL) {
        let record = DictationRecord(meta: meta, folder: folder)
        do {
            try queue.write { db in
                try record.save(db)
            }
            Self.notifyChanged()
        } catch {
            Log.history.error("HistoryStore: upsert failed: \(error)")
        }
    }

    public func delete(id: String, removeFolder: Bool) {
        do {
            let record = try queue.write { db -> DictationRecord? in
                let record = try DictationRecord.fetchOne(db, key: id)
                try DictationRecord.deleteOne(db, key: id)
                return record
            }
            if removeFolder, let record {
                try? FileManager.default.removeItem(at: record.folderURL)
            }
            Self.notifyChanged()
        } catch {
            Log.history.error("HistoryStore: delete failed: \(error)")
        }
    }

    public func deleteAll(removeFolders: Bool, sparing activeFolder: URL? = nil) {
        do {
            _ = try queue.write { db in
                try DictationRecord.deleteAll(db)
            }
            Self.notifyChanged()
        } catch {
            Log.history.error("HistoryStore: deleteAll failed: \(error)")
        }
        if removeFolders {
            // Sweep the DIRECTORY, not the query — the visible-records filter hides
            // cancelled sessions whose audio would otherwise survive (audit #5).
            // The live session's folder is spared (audit L7).
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: FileLayout.recordingsRoot, includingPropertiesForKeys: nil
            )) ?? []
            for folder in folders where folder.hasDirectoryPath {
                if let activeFolder, folder.standardizedFileURL == activeFolder.standardizedFileURL {
                    continue
                }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Rebuild the index from the folders on disk (launch reconciliation).
    /// Folders are the source of truth: rows whose folders vanished (external
    /// cleanup, Finder deletion) are pruned, never shown as ghosts.
    public func reindex(recordingsRoot: URL = FileLayout.recordingsRoot) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: nil
        )) ?? []
        for folder in folders where folder.hasDirectoryPath {
            if let meta = SessionMeta.read(from: folder) {
                upsert(meta: meta, folder: folder)
            }
        }
        // Prune orphaned rows — from the UNFILTERED table. records() hides
        // silent/short-cancelled rows, and exactly those would otherwise linger
        // forever as invisible ghosts after external folder cleanup.
        let all = (try? queue.read { db in
            try DictationRecord.fetchAll(db)
        }) ?? []
        let orphans = all.filter {
            !FileManager.default.fileExists(atPath: $0.folder)
        }
        for orphan in orphans {
            delete(id: orphan.id, removeFolder: false)
        }
        if !orphans.isEmpty {
            Log.history.info("reindex pruned \(orphans.count) orphaned row(s)")
        }
    }

    // MARK: - Reads

    public func records(matching query: String? = nil, limit: Int = 500) -> [DictationRecord] {
        // History is a library of words + things needing attention — never an
        // event log. Visible: anything with a transcript; retryable failures and
        // offline-queued items; long cancelled recordings (recoverable). Silent
        // rows and short cancels are discarded at the source and filtered here
        // for legacy data. In-flight statuses (recording/recorded/transcribing)
        // are NOT visible: the live session would surface in the attention shelf
        // with Retry/Discard controls that double-upload or destroy it mid-flight
        // (production pass 2); crash recovery reads them via interruptedRecords()
        // and normalizes every one at launch.
        let visible = """
            (rawTranscript IS NOT NULL OR cleanedTranscript IS NOT NULL
             OR status IN ('failed','queuedForRetry')
             OR (status = 'cancelled' AND durationSeconds >= 10))
            AND status != 'silent'
            """
        return (try? queue.read { db in
            if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                // Escape LIKE wildcards so "100%" finds "100%" (audit L28).
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                return try DictationRecord
                    .filter(sql: "(rawTranscript LIKE ? ESCAPE '\\' OR cleanedTranscript LIKE ? ESCAPE '\\' OR targetAppName LIKE ? ESCAPE '\\') AND \(visible)",
                            arguments: [pattern, pattern, pattern])
                    .order(sql: "startedAt DESC")
                    .limit(limit)
                    .fetchAll(db)
            }
            return try DictationRecord
                .filter(sql: visible)
                .order(sql: "startedAt DESC")
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    /// Every row id, visibility filter bypassed — test-only observability.
    func allIDsForTesting() -> [String] {
        (try? queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM dictation ORDER BY startedAt")
        }) ?? []
    }

    /// Sessions the RetryQueue should drain: offline-queued plus transient failures.
    public func retryableRecords() -> [DictationRecord] {
        (try? queue.read { db in
            try DictationRecord
                .filter(sql: "status = ? OR (status = ? AND errorCode IN (?, ?, ?))",
                        arguments: [SessionMeta.Status.queuedForRetry.rawValue,
                                    SessionMeta.Status.failed.rawValue,
                                    "network", "timeout", "rate_limit"])
                .order(sql: "startedAt ASC")
                .fetchAll(db)
        }) ?? []
    }

    /// Non-terminal sessions found at launch = the app died mid-flight.
    public func interruptedRecords() -> [DictationRecord] {
        (try? queue.read { db in
            try DictationRecord
                .filter(sql: "status IN (?, ?, ?)",
                        arguments: [SessionMeta.Status.recording.rawValue,
                                    SessionMeta.Status.recorded.rawValue,
                                    SessionMeta.Status.transcribing.rawValue])
                .order(sql: "startedAt DESC")
                .fetchAll(db)
        }) ?? []
    }

    public struct Stats: Equatable, Sendable {
        public var totalWords: Int
        public var totalDictations: Int
        public var averageWPM: Int

        public init(totalWords: Int, totalDictations: Int, averageWPM: Int) {
            self.totalWords = totalWords
            self.totalDictations = totalDictations
            self.averageWPM = averageWPM
        }
    }

    public func stats() -> Stats {
        (try? queue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT cleanedTranscript, durationSeconds FROM dictation
                WHERE cleanedTranscript IS NOT NULL
                """)
            var words = 0
            var timedWords = 0
            var speech = 0.0
            for row in rows {
                let text: String = row["cleanedTranscript"] ?? ""
                // Whitespace-aware split (newlines count too — audit L29).
                let count = text.split(whereSeparator: \.isWhitespace).count
                words += count
                if let duration: Double = row["durationSeconds"], duration > 0 {
                    timedWords += count
                    speech += duration
                }
            }
            // WPM only over rows that actually have a duration.
            let wpm = speech > 10 ? Int(Double(timedWords) / (speech / 60)) : 0
            return Stats(totalWords: words, totalDictations: rows.count, averageWPM: wpm)
        }) ?? Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    }
}
