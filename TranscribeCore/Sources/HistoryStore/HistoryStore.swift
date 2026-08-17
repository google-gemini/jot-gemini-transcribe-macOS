import Foundation
import GRDB

/// Queryable index over the session folders (which remain the source of truth —
/// meta.json per folder). The DB makes History fast to search and stats cheap.
public struct DictationRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
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
        self.pipelineSeconds = meta.pipelineSeconds
    }
}

public final class HistoryStore: @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        queue = try DatabaseQueue(path: databaseURL.path)
        try migrate()
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
        try migrator.migrate(queue)
    }

    // MARK: - Writes

    public func upsert(meta: SessionMeta, folder: URL) {
        let record = DictationRecord(meta: meta, folder: folder)
        do {
            try queue.write { db in
                try record.save(db)
            }
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
        } catch {
            Log.history.error("HistoryStore: delete failed: \(error)")
        }
    }

    /// Rebuild the index from the folders on disk (launch reconciliation).
    public func reindex(recordingsRoot: URL = FileLayout.recordingsRoot) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: recordingsRoot, includingPropertiesForKeys: nil
        )) ?? []
        for folder in folders where folder.hasDirectoryPath {
            if let meta = SessionMeta.read(from: folder) {
                upsert(meta: meta, folder: folder)
            }
        }
    }

    // MARK: - Reads

    public func records(matching query: String? = nil, limit: Int = 500) -> [DictationRecord] {
        (try? queue.read { db in
            if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let pattern = "%\(query)%"
                return try DictationRecord
                    .filter(sql: "rawTranscript LIKE ? OR cleanedTranscript LIKE ? OR targetAppName LIKE ?",
                            arguments: [pattern, pattern, pattern])
                    .order(sql: "startedAt DESC")
                    .limit(limit)
                    .fetchAll(db)
            }
            return try DictationRecord
                .order(sql: "startedAt DESC")
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    /// Sessions the RetryQueue should drain: offline-queued plus transient failures.
    public func retryableRecords() -> [DictationRecord] {
        (try? queue.read { db in
            try DictationRecord
                .filter(sql: "status = ? OR (status = ? AND errorCode IN (?, ?))",
                        arguments: [SessionMeta.Status.queuedForRetry.rawValue,
                                    SessionMeta.Status.failed.rawValue,
                                    "network", "timeout"])
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
            var speech = 0.0
            for row in rows {
                let text: String = row["cleanedTranscript"] ?? ""
                words += text.split(separator: " ").count
                speech += row["durationSeconds"] ?? 0.0
            }
            let wpm = speech > 10 ? Int(Double(words) / (speech / 60)) : 0
            return Stats(totalWords: words, totalDictations: rows.count, averageWPM: wpm)
        }) ?? Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    }
}
