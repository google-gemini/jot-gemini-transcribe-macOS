import Foundation

/// Where everything lives on disk. One folder per dictation, Superwhisper-proven
/// layout: audio.caf (crash-safe master), audio.flac (upload copy, M3+), meta.json.
public enum FileLayout {
    public static var appSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Google Transcribe", isDirectory: true)
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
    public static func audioFLAC(in folder: URL) -> URL { folder.appendingPathComponent("audio.flac") }
    public static func metaJSON(in folder: URL) -> URL { folder.appendingPathComponent("meta.json") }
}
