import Foundation

/// Where everything lives on disk. One folder per dictation, Superwhisper-proven
/// layout: audio.caf (crash-safe master), audio.flac (upload copy, M3+), meta.json.
public enum FileLayout {
    /// Test hook: unit tests MUST sandbox here — the suite once wrote failed-
    /// session folders straight into the user's real History.
    public static var overrideRoot: URL?

    public static var appSupportRoot: URL {
        if let overrideRoot { return overrideRoot }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jot", isDirectory: true)
    }

    public static var recordingsRoot: URL {
        appSupportRoot.appendingPathComponent("recordings", isDirectory: true)
    }

    /// Creates (if needed) and returns a fresh session folder. Name is
    /// timestamp-prefixed for human sortability in Finder.
    public static func makeSessionFolder(id: UUID, now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(formatter.string(from: now))-\(id.uuidString.prefix(8))"
        let url = recordingsRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func audioCAF(in folder: URL) -> URL { folder.appendingPathComponent("audio.caf") }

    /// Duration estimate from CAF byte size (16kHz mono Int16 ≈ 32,000 B/s) — for
    /// crash-recovered sessions whose meta never got a duration (audit #7).
    public static func estimatedDuration(ofCAF url: URL) -> Double? {
        guard let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              bytes > 4096 else { return nil }
        return Double(bytes) / 32_000
    }
    public static func audioFLAC(in folder: URL) -> URL { folder.appendingPathComponent("audio.flac") }
    public static func metaJSON(in folder: URL) -> URL { folder.appendingPathComponent("meta.json") }
}
