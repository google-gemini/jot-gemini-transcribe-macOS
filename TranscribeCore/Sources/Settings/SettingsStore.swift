import Foundation

/// UserDefaults-backed settings (M3 minimal; the Settings UI lands at M7).
/// Endpoint + model IDs are overridable because preview models get renamed.
public struct SettingsStore: Sendable {
    private static let defaults = UserDefaults.standard

    public init() {}

    public var geminiConfig: GeminiConfig {
        var config = GeminiConfig()
        if let raw = Self.defaults.string(forKey: "endpointOverride"), let url = URL(string: raw) {
            config.endpoint = url
        }
        if let model = Self.defaults.string(forKey: "transcribeModelOverride"), !model.isEmpty {
            config.transcribeModel = model
        }
        if let model = Self.defaults.string(forKey: "cleanupModelOverride"), !model.isEmpty {
            config.cleanupModel = model
        }
        return config
    }

    /// Smart formatting = the cleanup pass. Off ⇒ verbatim (raw transcript, which
    /// still has model-native punctuation).
    public var smartFormattingEnabled: Bool {
        Self.defaults.object(forKey: "smartFormatting") as? Bool ?? true
    }

    /// Double-tap the dictation key to lock hands-free. Optional because tap-tap
    /// can collide with quick hold sessions (first dogfood feedback).
    public var doubleTapLockEnabled: Bool {
        Self.defaults.object(forKey: "doubleTapLock") as? Bool ?? true
    }

    public func setDoubleTapLock(_ enabled: Bool) {
        Self.defaults.set(enabled, forKey: "doubleTapLock")
    }

    public func setSmartFormatting(_ enabled: Bool) {
        Self.defaults.set(enabled, forKey: "smartFormatting")
    }

    /// Days to keep audio files (transcripts are kept until deleted). 0 = forever.
    public var audioRetentionDays: Int {
        Self.defaults.object(forKey: "audioRetentionDays") as? Int ?? 7
    }

    public func setAudioRetentionDays(_ days: Int) {
        Self.defaults.set(days, forKey: "audioRetentionDays")
    }

    /// Auto-degrade bookkeeping (F11): ≥3 gate trips in 24h ⇒ verbatim by default.
    public func recordGateTrip(now: Date = Date()) -> Int {
        var trips = (Self.defaults.array(forKey: "gateTrips") as? [Date]) ?? []
        trips = trips.filter { now.timeIntervalSince($0) < 86_400 }
        trips.append(now)
        Self.defaults.set(trips, forKey: "gateTrips")
        return trips.count
    }
}
