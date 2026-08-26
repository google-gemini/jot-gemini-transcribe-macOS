// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

public extension Notification.Name {
    /// Posted after any SettingsStore write and after Keychain API-key writes,
    /// with `object` = the key ("showIdleIndicator", "apiKey", …). Runtime
    /// surfaces that render a setting (pill, status line, hotkey engine) observe
    /// this so toggles take effect the moment they're flipped — never "on the
    /// next unrelated transition". (gateTrips bookkeeping is exempt: nothing
    /// renders it.)
    static let gtSettingDidChange = Notification.Name("com.ammaar.jot.setting-changed")

    /// Posted when the gate auto-disables the opt-in tone pass (3 trips in 24h)
    /// so the app can tell the user instead of silently dropping it. Native smart
    /// transcription is unaffected — the user loses an extra, not their words.
    static let gtSmartFormattingAutoDegraded = Notification.Name("com.ammaar.jot.auto-degraded")
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

    /// Single source of truth for endpoint-override validity — the Settings UI
    /// warning and the effective config MUST use the same predicate, or one of
    /// them lies about which endpoint is in use.
    public static func usableEndpointURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    /// True once the user finished onboarding — a deliberate "I'll add it later"
    /// must not re-trap them in the wizard every launch.
    public var hasCompletedOnboarding: Bool {
        Self.defaults.bool(forKey: "hasCompletedOnboarding")
    }

    public func setHasCompletedOnboarding(_ done: Bool) {
        Self.set(done, forKey: "hasCompletedOnboarding")
    }

    public var geminiConfig: GeminiConfig {
        var config = GeminiConfig()
        if let url = Self.usableEndpointURL(Self.defaults.string(forKey: "endpointOverride")) {
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

    /// Double-tap the dictation key to lock hands-free. OFF by default: firm taps
    /// routinely exceed the hold threshold, misreading tap-tap as hold→finalize
    /// (dogfood). The timing-free gesture is Space-while-holding.
    public var doubleTapLockEnabled: Bool {
        Self.defaults.object(forKey: "doubleTapLock") as? Bool ?? false
    }

    public func setDoubleTapLock(_ enabled: Bool) {
        Self.set(enabled, forKey: "doubleTapLock")
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

    /// Send every dictation to the clipboard instead of the cursor. Off by
    /// default — the point of the app is that words land where you were already
    /// typing. On for destinations the ladder cannot serve: remote desktops, VMs,
    /// canvas apps. A MODE, not the automatic fallback — the ladder still diverts
    /// on its own when it can prove there is nowhere to type.
    public var dictateToClipboard: Bool {
        Self.defaults.object(forKey: "dictateToClipboard") as? Bool ?? false
    }

    public func setDictateToClipboard(_ enabled: Bool) {
        Self.set(enabled, forKey: "dictateToClipboard")
    }

    /// Leave every transcript on the clipboard AFTER inserting it, so the last
    /// dictation is always re-pasteable. Off by default because it has a cost:
    /// the clipboard is restored ~1s after a paste precisely so dictating doesn't
    /// destroy what you had copied, and keeping the transcript gives that up.
    public var keepOnClipboard: Bool {
        Self.defaults.object(forKey: "keepOnClipboard") as? Bool ?? false
    }

    public func setKeepOnClipboard(_ enabled: Bool) {
        Self.set(enabled, forKey: "keepOnClipboard")
    }

    public var hotkeyKey: HotkeyKey {
        (Self.defaults.string(forKey: "hotkeyKey")).flatMap(HotkeyKey.init(rawValue:)) ?? .fn
    }

    // MARK: - Formatting policy

    /// How a dictation gets formatted. Two independent flags rather than a
    /// three-valued enum, because all four combinations are meaningful — in
    /// particular (nativeSmart: false, cleanupPass: true) is the exact pipeline
    /// Jot shipped before native smart existed, and that is the configuration you
    /// want reachable if smart mode ever regresses server-side.
    public struct FormattingPolicy: Equatable, Sendable {
        public var nativeSmart: Bool
        public var cleanupPass: Bool

        public init(nativeSmart: Bool, cleanupPass: Bool) {
            self.nativeSmart = nativeSmart
            self.cleanupPass = cleanupPass
        }

        public var mode: GeminiClient.TranscriptionMode { nativeSmart ? .smart : .verbatim }
        /// The gate only has a real reference to compare against when a second
        /// model actually rewrote the text.
        public var runsValidationGate: Bool { cleanupPass }
    }

    public var formattingPolicy: FormattingPolicy {
        FormattingPolicy(
            nativeSmart: Self.defaults.object(forKey: "smartTranscription") as? Bool ?? true,
            cleanupPass: Self.defaults.object(forKey: "smartCleanupPass") as? Bool ?? false
        )
    }

    /// Native `mode: "smart"` — the default transcription path.
    public var smartTranscriptionEnabled: Bool {
        Self.defaults.object(forKey: "smartTranscription") as? Bool ?? true
    }

    public func setSmartTranscription(_ enabled: Bool) {
        Self.set(enabled, forKey: "smartTranscription")
    }

    /// The opt-in second pass through the cleanup model — this is what carries
    /// per-app tone. Off by default: it costs a round trip and sends the
    /// transcript text a second time.
    public var smartCleanupPassEnabled: Bool {
        Self.defaults.object(forKey: "smartCleanupPass") as? Bool ?? false
    }

    public func setSmartCleanupPass(_ enabled: Bool) {
        if enabled {
            // A deliberate re-enable is a clean slate. This moved here with the
            // gate counter: auto-degrade now switches THIS flag off, so leaving
            // the clear on setSmartFormatting would resurrect the bug where one
            // stale trip inside the old 24h window instantly re-degrades.
            Self.defaults.removeObject(forKey: "gateTrips")
        }
        Self.set(enabled, forKey: "smartCleanupPass")
    }

    /// Escape hatch back to the pre-native-smart transport.
    ///
    /// `/v1beta/interactions` is days old. For the cost of one settings row, a
    /// server-side regression in smart mode becomes something a user can switch
    /// off rather than something that needs a hotfix release. Smart formatting is
    /// unavailable on the legacy endpoint (`mode` returns an empty transcript
    /// there), so this necessarily means verbatim + the optional tone pass.
    /// Remove once native smart has a clean dogfood run.
    public var usesLegacyTranscribeEndpoint: Bool {
        Self.defaults.bool(forKey: "legacyTranscribeEndpoint")
    }

    public func setLegacyTranscribeEndpoint(_ enabled: Bool) {
        Self.set(enabled, forKey: "legacyTranscribeEndpoint")
    }

    public func setHotkeyKey(_ key: HotkeyKey) {
        Self.set(key.rawValue, forKey: "hotkeyKey")
    }

    /// Experimental: judge speech RELATIVE to the room instead of against fixed
    /// thresholds that assume a quiet one, and (once probed) let macOS suppress
    /// background voices. Off by default until dogfood data earns the flip.
    ///
    /// One key gates every behaviour in the noise work, so there is exactly one
    /// thing to turn on, one thing to turn off, and one thing to flip when the
    /// numbers are in. The measurements it would act on are recorded either way —
    /// `NoiseFloorEstimator` runs unconditionally.
    public var experimentalNoiseHandling: Bool {
        Self.defaults.bool(forKey: "experimentalNoiseHandling")
    }

    public func setExperimentalNoiseHandling(_ enabled: Bool) {
        Self.set(enabled, forKey: "experimentalNoiseHandling")
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
