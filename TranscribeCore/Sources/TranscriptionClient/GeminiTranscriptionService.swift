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

        let deadline = TimeoutPolicy.overallDeadline(audioDuration: durationSeconds)
        let raw = try await transcribeWithRetry(flacData: flacData, config: config, deadline: deadline)

        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            // Distinguishing true silence (F9b) from a dropped transcript (F9a) needs
            // the audio-energy check; durationSeconds < 1s with no text ⇒ silence-ish.
            throw TranscriptionError.emptyTranscript
        }

        guard settings.smartFormattingEnabled else {
            return TranscriptionResult(rawTranscript: trimmedRaw, cleanedTranscript: trimmedRaw, modelID: config.transcribeModel)
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
            default:
                throw error
            }
        }
    }

    private func cleanupOrFallback(raw: String, context: DictationContext, config: GeminiConfig) async -> String {
        let tone = PromptV1.toneCategory(forBundleID: context.targetAppBundleID)
        let prompt = PromptV1.cleanupPrompt(raw: raw, tone: tone)
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
                return raw
            }
            return cleaned
        } catch {
            // Deadline miss / network hiccup on cleanup never costs the dictation.
            Log.transcription.info("cleanup unavailable (\(String(describing: error), privacy: .public)) — inserting raw")
            return raw
        }
    }
}
