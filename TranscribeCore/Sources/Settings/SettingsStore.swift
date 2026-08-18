import Foundation

public extension Notification.Name {
    /// Posted after any SettingsStore write and after Keychain API-key writes,
    /// with `object` = the key ("showIdleIndicator", "apiKey", …). Runtime
    /// surfaces that render a setting (pill, status line, hotkey engine) observe
    /// this so toggles take effect the moment they're flipped — never "on the
    /// next unrelated transition". (gateTrips bookkeeping is exempt: nothing
    /// renders it.)
    static let gtSettingDidChange = Notification.Name("com.google.transcribe.setting-changed")

    /// Posted when the gate auto-disables smart formatting (3 trips in 24h) so
    /// the app can tell the user instead of silently going verbatim.
    static let gtSmartFormattingAutoDegraded = Notification.Name("com.google.transcribe.auto-degraded")
}

/// UserDefaults-backed settings (M3 minimal; the Settings UI lands at M7).
/// Endpoint + model IDs are overridable because preview models get renamed.
public struct SettingsStore: Sendable {
    private static let defaults = UserDefaults.standard

    public init() {}

    private static func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: key)
    }

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

    /// Double-tap the dictation key to lock hands-free. OFF by default: firm taps
    /// routinely exceed the hold threshold, misreading tap-tap as hold→finalize
    /// (dogfood). The timing-free gesture is Space-while-holding.
    public var doubleTapLockEnabled: Bool {
        Self.defaults.object(forKey: "doubleTapLock") as? Bool ?? false
    }

    public func setDoubleTapLock(_ enabled: Bool) {
        Self.set(enabled, forKey: "doubleTapLock")
    }

    public func setSmartFormatting(_ enabled: Bool) {
        if enabled {
            // A deliberate re-enable is a clean slate — without this, one more
            // gate trip inside the old 24h window re-degrades instantly and the
            // user's choice silently loses.
            Self.defaults.removeObject(forKey: "gateTrips")
        }
        Self.set(enabled, forKey: "smartFormatting")
    }

    /// Show the resting dot at the bottom of the screen when idle. Off = the pill
    /// only appears while dictating.
    public var showIdleIndicator: Bool {
        Self.defaults.object(forKey: "showIdleIndicator") as? Bool ?? true
    }

    public func setShowIdleIndicator(_ show: Bool) {
        Self.set(show, forKey: "showIdleIndicator")
    }

    public var soundsEnabled: Bool {
        Self.defaults.object(forKey: "soundsEnabled") as? Bool ?? true
    }

    public func setSoundsEnabled(_ enabled: Bool) {
        Self.set(enabled, forKey: "soundsEnabled")
    }

    public var hotkeyKey: HotkeyKey {
        (Self.defaults.string(forKey: "hotkeyKey")).flatMap(HotkeyKey.init(rawValue:)) ?? .fn
    }

    public func setHotkeyKey(_ key: HotkeyKey) {
        Self.set(key.rawValue, forKey: "hotkeyKey")
    }

    // Raw override values for the Settings UI — panes must not duplicate the
    // defaults keys (a rename would silently desync display from effect).
    public var endpointOverride: String? { Self.defaults.string(forKey: "endpointOverride") }
    public var transcribeModelOverride: String? { Self.defaults.string(forKey: "transcribeModelOverride") }
    public var cleanupModelOverride: String? { Self.defaults.string(forKey: "cleanupModelOverride") }

    public func setEndpointOverride(_ raw: String?) {
        Self.set(raw, forKey: "endpointOverride")
    }

    public func setTranscribeModelOverride(_ raw: String?) {
        Self.set(raw, forKey: "transcribeModelOverride")
    }

    public func setCleanupModelOverride(_ raw: String?) {
        Self.set(raw, forKey: "cleanupModelOverride")
    }

    /// Days to keep audio files (transcripts are kept until deleted). 0 = forever.
    public var audioRetentionDays: Int {
        Self.defaults.object(forKey: "audioRetentionDays") as? Int ?? 7
    }

    public func setAudioRetentionDays(_ days: Int) {
        Self.set(days, forKey: "audioRetentionDays")
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
