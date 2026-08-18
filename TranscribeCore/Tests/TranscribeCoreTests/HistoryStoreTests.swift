import XCTest
@testable import TranscribeCore

final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("recordings", isDirectory: true),
            withIntermediateDirectories: true
        )
        store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(status: SessionMeta.Status, transcript: String?, onDisk: Bool) throws -> SessionMeta {
        var meta = SessionMeta(id: UUID(), startedAt: Date(), status: status)
        meta.rawTranscript = transcript
        let folder = root
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(meta.id.uuidString, isDirectory: true)
        if onDisk {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            meta.write(to: folder)
        }
        store.upsert(meta: meta, folder: folder)
        return meta
    }

    /// Rows whose folders vanished must be pruned even when the visibility
    /// filter hides them (silent / short-cancelled) — otherwise they linger as
    /// invisible ghosts forever and the DB stops mirroring the disk.
    func testReindexPrunesInvisibleOrphans() throws {
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        _ = try makeSession(status: .silent, transcript: nil, onDisk: false)
        _ = try makeSession(status: .cancelled, transcript: nil, onDisk: false)
        let keptVisible = try makeSession(status: .inserted, transcript: "hello there", onDisk: true)
        let keptInvisible = try makeSession(status: .silent, transcript: nil, onDisk: true)

        store.reindex(recordingsRoot: recordings)

        let remaining = Set(store.allIDsForTesting())
        XCTAssertEqual(remaining, [keptVisible.id.uuidString, keptInvisible.id.uuidString])
    }

    func testReindexKeepsRowsWithFolders() throws {
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let kept = try makeSession(status: .inserted, transcript: "still here", onDisk: true)
        store.reindex(recordingsRoot: recordings)
        XCTAssertEqual(store.allIDsForTesting(), [kept.id.uuidString])
    }
}
