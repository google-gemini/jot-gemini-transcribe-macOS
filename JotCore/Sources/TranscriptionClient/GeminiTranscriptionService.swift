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

/// The transcription pipeline.
///
///   CAF → FLAC → interactions (mode: smart, custom_vocabulary)
///       → [optional] flash-lite cleanup for per-app tone → validation gate
///       → ReplacementEngine → inserted text.
///
/// The model now does filler removal, self-correction collapse and list
/// formatting itself, so the default path is ONE call. The cleanup pass survives
/// as an opt-in because it is the only thing that carries per-app tone.
///
/// Rules unchanged: one silent retry on transient transcribe failures; cleanup
/// has a hard deadline and NEVER blocks a good transcript; every failure is a
/// typed TranscriptionError mapping to the failure matrix.
public struct GeminiTranscriptionService: TranscriptionServicing {
    private let client: GeminiClient
    private let settings: SettingsStore
    /// Cleanup budget: probe median 0.3s; hard cap so raw fallback keeps us fast.
    static let cleanupDeadline: TimeInterval = 1.5

    public init(client: GeminiClient, settings: SettingsStore = SettingsStore()) {
        self.client = client
        self.settings = settings
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        let config = settings.geminiConfig
        let flacURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio.flac")

        let encoded = try FLACEncoder.encode(cafURL: audioURL, flacURL: flacURL)
        Log.transcription.info("FLAC \(encoded.byteCount) bytes in \(Int(encoded.encodeSeconds * 1000))ms")
        let flacData = try Data(contentsOf: encoded.url)
        // The FLAC is derived data (re-encoded from the CAF on any retry) — once
        // it's in memory the file is pure duplication. Storage policy: the CAF is
        // the only audio artifact that persists.
        try? FileManager.default.removeItem(at: encoded.url)

        let policy = settings.formattingPolicy
        // Read once per dictation: a toggle flipped mid-flight must not change
        // the rules this transcript is being produced under.
        let vocabulary = Self.vocabularyIfEnabled()
        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)
        var raw = try await transcribeWithRetry(
            flacData: flacData, config: config, policy: policy,
            vocabulary: vocabulary, deadline: deadline
        )

        var trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRaw.isEmpty, durationSeconds >= 0.6 {
            // F9a second chance: an empty result on real audio is sometimes model
            // nondeterminism — one re-send before surfacing anything (audit L25).
            Log.transcription.info("empty transcript on \(String(format: "%.1f", durationSeconds))s audio — one re-send")
            // NB: goes through the same policy-aware call as the primary path.
            // Sending this one down the old endpoint would leave a rare branch
            // silently on a different pipeline.
            raw = (try? await sendTranscribe(
                flacData: flacData, config: config, policy: policy,
                vocabulary: vocabulary, deadline: deadline
            )) ?? ""
            trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmedRaw.isEmpty else {
            // The coordinator classifies silence vs dropped-transcript by energy.
            throw TranscriptionError.emptyTranscript
        }

        guard policy.cleanupPass else {
            // Dictionary rules are a HARD guarantee — they apply on every path
            // (audit L9). The gate is deliberately NOT run here: with no second
            // model there is no independent reference, and validate(raw:X, cleaned:X)
            // passes trivially, so running it would be theatre rather than safety.
            let rules = DictionaryStore().replacementRules()
            let text = ReplacementEngine.apply(rules, to: trimmedRaw)
            return TranscriptionResult(
                rawTranscript: trimmedRaw,
                cleanedTranscript: text,
                modelID: "\(config.transcribeModel)/\(policy.mode.rawValue)"
            )
        }

        let cleaned = await cleanupOrFallback(raw: trimmedRaw, context: context, config: config)
        return TranscriptionResult(
            rawTranscript: trimmedRaw,
            cleanedTranscript: cleaned,
            modelID: "\(config.transcribeModel)/\(policy.mode.rawValue)+\(config.cleanupModel)"
        )
    }

    // MARK: - Stages

    /// Vocabulary is suppressed once it has PROVABLY broken a request.
    ///
    /// Keyed on the vocabulary itself rather than a bare flag: editing the
    /// Dictionary changes the key and we try again, so one bad entry cannot
    /// disable the feature until relaunch with nothing telling the user why.
    private static let vocabularySuppressed = Suppression()
    final class Suppression: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked: Int?
        func isBlocked(_ vocabulary: [String]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return blocked != nil && blocked == vocabulary.hashValue
        }
        func block(_ vocabulary: [String]) {
            lock.lock(); blocked = vocabulary.hashValue; lock.unlock()
        }
    }

    private static func vocabularyIfEnabled() -> [String] {
        let vocabulary = DictionaryStore().sanitizedVocabulary()
        return vocabularySuppressed.isBlocked(vocabulary) ? [] : vocabulary
    }

    /// The ONE place a transcription request is sent. Every caller — primary,
    /// silent retry, and the empty-transcript second chance — goes through here.
    private func sendTranscribe(
        flacData: Data, config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        // The transport decision lives in ONE place so the fail-open retry below
        // cannot silently switch endpoints half way through a recovery.
        func send(_ terms: [String]) async throws -> String {
            if settings.usesLegacyTranscribeEndpoint {
                // Verbatim only — `mode` returns an empty transcript on this
                // endpoint. The tone pass, if enabled, still runs on top.
                return try await client.transcribe(
                    flacData: flacData, model: config.transcribeModel,
                    endpoint: config.endpoint, deadline: deadline, customVocabulary: terms
                )
            }
            return try await client.transcribeInteraction(
                audio: flacData, model: config.transcribeModel, endpoint: config.endpoint,
                mode: policy.mode, customVocabulary: terms, deadline: deadline
            )
        }

        do {
            return try await send(vocabulary)
        } catch TranscriptionError.badRequest(let message) where !vocabulary.isEmpty {
            // Fail open. badRequest is deliberately terminal everywhere else, but
            // one strange dictionary entry must never be able to break a user's
            // own dictation. Covers BOTH transports — the legacy endpoint carries
            // vocabulary too.
            Log.transcription.error("transcribe rejected with vocabulary (\(message, privacy: .private)) — retrying without it")
            let text = try await send([])
            // Only latch once the vocabulary-free retry SUCCEEDS. If it also
            // fails, the vocabulary was innocent — and a bad API key returns 400
            // here, not 401, so latching eagerly would disable the Dictionary for
            // the rest of the launch over an auth problem.
            Self.vocabularySuppressed.block(vocabulary)
            return text
        }
    }

    private func transcribeWithRetry(
        flacData: Data, config: GeminiConfig, policy: SettingsStore.FormattingPolicy,
        vocabulary: [String], deadline: TimeInterval
    ) async throws -> String {
        do {
            return try await sendTranscribe(
                flacData: flacData, config: config, policy: policy,
                vocabulary: vocabulary, deadline: deadline
            )
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                // One silent retry for transient classes (audio is safe on disk).
                Log.transcription.info("transcribe retrying after \(String(describing: error), privacy: .public)")
                try await Task.sleep(nanoseconds: 500_000_000)
                return try await sendTranscribe(
                    flacData: flacData, config: config, policy: policy,
                    vocabulary: vocabulary, deadline: deadline
                )
            default:
                throw error
            }
        }
    }

    private func cleanupOrFallback(raw: String, context: DictationContext, config: GeminiConfig) async -> String {
        let tone = PromptV1.toneCategory(forBundleID: context.targetAppBundleID)
        let dictionary = DictionaryStore()
        let prompt = PromptV1.cleanupPrompt(
            raw: raw,
            tone: tone,
            vocabulary: dictionary.sanitizedVocabulary(),
            spellings: dictionary.spellings()
        )
        do {
            let response = try await client.cleanup(
                prompt: prompt, model: config.cleanupModel,
                endpoint: config.endpoint, deadline: Self.cleanupDeadline
            )
            let cleaned = ValidationGate.stripArtifacts(response)
            let verdict = ValidationGate.validate(raw: raw, cleaned: cleaned)
            guard verdict.accepted else {
                let trips = settings.recordGateTrip()
                Log.transcription.warning("cleanup gate REJECTED (\(verdict.reason ?? "?", privacy: .public), trip #\(trips) in 24h) — inserting raw")
                autoDegradeIfNeeded(trips: trips)
                return ReplacementEngine.apply(dictionary.replacementRules(), to: raw)
            }
            // The dictionary's hard guarantee: explicit wrong→right rules always win.
            return ReplacementEngine.apply(dictionary.replacementRules(), to: cleaned)
        } catch {
            // Deadline miss / network hiccup on cleanup never costs the dictation —
            // and the dictionary guarantee still holds (audit L9).
            Log.transcription.info("cleanup unavailable (\(String(describing: error), privacy: .public)) — inserting raw")
            return ReplacementEngine.apply(dictionary.replacementRules(), to: raw)
        }
    }

    /// F11 auto-degrade (audit L10): three gate trips in 24h means cleanup can't
    /// be trusted right now — switch to exact transcription until re-enabled.
    private func autoDegradeIfNeeded(trips: Int) {
        guard trips >= 3, settings.smartCleanupPassEnabled else { return }
        settings.setSmartCleanupPass(false)
        NotificationCenter.default.post(name: .gtSmartFormattingAutoDegraded, object: nil)
        Log.transcription.warning("cleanup unreliable (3 gate trips in 24h) — tone pass auto-disabled; smart transcription unaffected")
    }
}
