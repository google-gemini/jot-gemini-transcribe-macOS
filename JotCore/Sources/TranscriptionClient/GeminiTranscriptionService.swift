import Foundation

/// The real two-call pipeline (endpoint-probe architecture):
///
///   CAF → FLAC → transcribe-preview (verbatim + punctuation, one lump)
///       → flash-lite cleanup (fillers, self-corrections, tone, dictionary)
///       → validation gate → cleaned text, or raw on any cleanup doubt.
///
/// Rules: one silent retry on transient transcribe failures; cleanup has a hard
/// deadline and NEVER blocks a good raw transcript; every failure is a typed
/// TranscriptionError mapping to the failure matrix.
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

        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)
        var raw = try await transcribeWithRetry(flacData: flacData, config: config, deadline: deadline)

        var trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRaw.isEmpty, durationSeconds >= 0.6 {
            // F9a second chance: an empty result on real audio is sometimes model
            // nondeterminism — one re-send before surfacing anything (audit L25).
            Log.transcription.info("empty transcript on \(String(format: "%.1f", durationSeconds))s audio — one re-send")
            raw = (try? await client.transcribe(
                flacData: flacData, model: config.transcribeModel,
                endpoint: config.endpoint, deadline: deadline
            )) ?? ""
            trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmedRaw.isEmpty else {
            // The coordinator classifies silence vs dropped-transcript by energy.
            throw TranscriptionError.emptyTranscript
        }

        guard settings.smartFormattingEnabled else {
            // Dictionary rules are a HARD guarantee — they apply on every path,
            // including verbatim mode (audit L9).
            let rules = DictionaryStore().replacementRules()
            let text = ReplacementEngine.apply(rules, to: trimmedRaw)
            return TranscriptionResult(rawTranscript: trimmedRaw, cleanedTranscript: text, modelID: config.transcribeModel)
        }

        let cleaned = await cleanupOrFallback(raw: trimmedRaw, context: context, config: config)
        return TranscriptionResult(
            rawTranscript: trimmedRaw,
            cleanedTranscript: cleaned,
            modelID: "\(config.transcribeModel)+\(config.cleanupModel)"
        )
    }

    // MARK: - Stages

    private func transcribeWithRetry(flacData: Data, config: GeminiConfig, deadline: TimeInterval) async throws -> String {
        do {
            return try await client.transcribe(
                flacData: flacData, model: config.transcribeModel,
                endpoint: config.endpoint, deadline: deadline
            )
        } catch let error as TranscriptionError {
            switch error {
            case .network, .timeout:
                // One silent retry for transient classes (audio is safe on disk).
                Log.transcription.info("transcribe retrying after \(String(describing: error), privacy: .public)")
                try await Task.sleep(nanoseconds: 500_000_000)
                return try await client.transcribe(
                    flacData: flacData, model: config.transcribeModel,
                    endpoint: config.endpoint, deadline: deadline
                )
            case .modelUnavailable:
                // This key has no access to the preferred model — walk the
                // fallbacks and REMEMBER the winner, so the 404 is paid once per
                // install instead of once per dictation.
                for candidate in GeminiConfig.transcribeFallbacks where candidate != config.transcribeModel {
                    do {
                        let text = try await client.transcribe(
                            flacData: flacData, model: candidate,
                            endpoint: config.endpoint, deadline: deadline
                        )
                        Log.transcription.info("transcribe model \(config.transcribeModel, privacy: .public) unavailable — switched to \(candidate, privacy: .public)")
                        settings.setTranscribeModelOverride(candidate)
                        return text
                    } catch let next as TranscriptionError {
                        if case .modelUnavailable = next { continue }
                        throw next
                    }
                }
                throw error
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
            vocabulary: dictionary.vocabulary(),
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
        guard trips >= 3, settings.smartFormattingEnabled else { return }
        settings.setSmartFormatting(false)
        NotificationCenter.default.post(name: .gtSmartFormattingAutoDegraded, object: nil)
        Log.transcription.warning("cleanup unreliable (3 gate trips in 24h) — smart formatting auto-disabled; re-enable in Settings")
    }
}
