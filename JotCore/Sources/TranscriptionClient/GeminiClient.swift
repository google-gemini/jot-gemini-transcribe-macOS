import Foundation

/// Endpoint + model configuration, overridable in Settings (preview models get
/// renamed; never hard-fail on a model name).
public struct GeminiConfig: Sendable, Equatable {
    public var endpoint: URL
    public var transcribeModel: String
    public var cleanupModel: String

    public init(
        endpoint: URL = URL(string: "https://generativelanguage.googleapis.com")!,
        // gemini-3.5-transcribe-PREVIEW was retired server-side on 2026-08-18;
        // the graduated name is gemini-3.5-transcribe (probed live, 200).
        // This is the specialist transcription model the team runs on — a
        // general Flash model is NOT an acceptable substitute for it (it
        // paraphrases, and handed bare audio it will answer instead of
        // transcribe). Only ever fall back within the transcribe family.
        transcribeModel: String = "gemini-3.5-transcribe",
        cleanupModel: String = "gemini-3.5-flash-lite"
    ) {
        self.endpoint = endpoint
        self.transcribeModel = transcribeModel
        self.cleanupModel = cleanupModel
    }

    /// Tried in order when the preferred model 404s — transcribe family ONLY.
    /// Preview models get renamed and retired without warning (it happened
    /// mid-session on 2026-08-18), so a same-family successor keeps dictation
    /// alive. Substituting a general Flash model would quietly change what the
    /// product IS, so it is not in this list.
    public static let transcribeFallbacks = [
        "gemini-3.5-transcribe",
        "a newer transcribe model",
    ]
}

/// Low-level Gemini API client. Uses non-streaming `generateContent`: the probe
/// showed the transcribe model delivers its entire result in one SSE lump anyway
/// (docs/design/endpoint-probe-results.md), so streaming buys nothing but parsing
/// complexity today. The bidi live model is the future streaming path.
public actor GeminiClient {
    private let session: URLSession
    private let apiKey: @Sendable () -> String?

    public init(apiKey: @escaping @Sendable () -> String?) {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false // fail fast into the retry/queue path
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
        self.apiKey = apiKey
    }

    // MARK: - Calls

    /// Audio-only request. The transcribe models ignore prompts, and
    /// audioTranscriptionConfig.wordTimestamp MUST be true or the transcript
    /// comes back empty.
    public func transcribe(flacData: Data, model: String, endpoint: URL, deadline: TimeInterval) async throws -> String {
        let parts: [[String: Any]] = [
            ["inline_data": ["mime_type": "audio/flac", "data": flacData.base64EncodedString()]],
        ]
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0,
                "audioTranscriptionConfig": ["wordTimestamp": true, "diarization": false],
            ],
        ]
        return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline)
    }

    /// Text-only cleanup call (flash-lite class, thinking minimized).
    /// The thinking knob differs by model generation (probed live):
    ///  - gemini-2.x: `thinkingConfig.thinkingBudget: 0`
    ///  - gemini-3.x+: `thinkingConfig.thinkingLevel: "low"` (thinkingBudget → 400;
    ///    bare/top-level thinkingLevel → 400; "low" measured faster and more
    ///    consistent than "minimal" on our eval set)
    public func cleanup(prompt: String, model: String, endpoint: URL, deadline: TimeInterval) async throws -> String {
        let thinkingConfig: [String: Any] = model.hasPrefix("gemini-2")
            ? ["thinkingBudget": 0]
            : ["thinkingLevel": "low"]
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]],
            ]],
            "generationConfig": [
                "temperature": 0,
                "thinkingConfig": thinkingConfig,
            ],
        ]
        return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline)
    }

    /// Cheap key validation for onboarding/Settings.
    public func validateKey(endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1beta/models").appending(queryItems: [URLQueryItem(name: "pageSize", value: "1")]))
        request.timeoutInterval = 10
        applyAuth(&request)
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// First model in `candidates` this key can actually reach, or nil if none.
    /// Onboarding runs this so "your key works" means the whole pipeline works,
    /// not just that the key authenticates.
    public func resolveAvailableModel(from candidates: [String], endpoint: URL) async -> String? {
        for model in candidates {
            var request = URLRequest(url: endpoint.appendingPathComponent("v1beta/models/\(model)"))
            request.timeoutInterval = 8
            applyAuth(&request)
            guard let (_, response) = try? await session.data(for: request) else { continue }
            if (response as? HTTPURLResponse)?.statusCode == 200 { return model }
        }
        return nil
    }

    // MARK: - Core

    private func generateContent(body: [String: Any], model: String, endpoint: URL, deadline: TimeInterval, isRetryAfter429: Bool = false) async throws -> String {
        let url = endpoint.appendingPathComponent("v1beta/models/\(model):generateContent")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = deadline
        applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            // URLRequest.timeoutInterval is an IDLE timer; enforce the true
            // overall deadline ourselves (audit L5).
            (data, response) = try await Self.withDeadline(seconds: deadline) { [session, request] in
                try await session.data(for: request)
            }
        } catch is DeadlineExceeded {
            throw TranscriptionError.timeout
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                throw TranscriptionError.offline
            case .timedOut:
                throw TranscriptionError.timeout
            default:
                throw TranscriptionError.network(error.code.rawValue.description)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("non-http")
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw TranscriptionError.auth
        case 403, 404:
            // Key authenticated but this model is gated (not available to this key), renamed,
            // or unknown. "Fix your key" would misdirect — name the model instead.
            let message = Self.errorMessage(from: data)
            Log.transcription.error("GeminiClient: \(http.statusCode) on \(model, privacy: .public) — \(message ?? "no detail", privacy: .private)")
            throw TranscriptionError.modelUnavailable(model: model, detail: message)
        case 429:
            // F5: per-minute throttles carry a short retryDelay — honor it once.
            if !isRetryAfter429, let delay = Self.retryDelaySeconds(from: data, headers: http), delay <= 8 {
                Log.transcription.info("GeminiClient: 429 with retryDelay \(delay, format: .fixed(precision: 1))s — waiting once")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await generateContent(body: body, model: model, endpoint: endpoint, deadline: deadline, isRetryAfter429: true)
            }
            // Only a real daily/hard quota is terminal; a per-minute throttle
            // (or an unparseable body) clears on its own and stays retryable.
            if let body = String(data: data, encoding: .utf8),
               let range = body.range(of: #""quotaId"\s*:\s*"[^"]*PerDay[^"]*""#, options: .regularExpression),
               !range.isEmpty {
                throw TranscriptionError.rateLimitedDaily
            }
            throw TranscriptionError.rateLimitedTransient
        case 400:
            // Permanent: malformed request — retrying is pointless.
            let message = Self.errorMessage(from: data) ?? "http_\(http.statusCode)"
            Log.transcription.error("GeminiClient: \(http.statusCode) — \(message, privacy: .private)")
            throw TranscriptionError.badRequest(message)
        case 500...599:
            throw TranscriptionError.network("http_\(http.statusCode)")
        default:
            let message = Self.errorMessage(from: data) ?? "http_\(http.statusCode)"
            Log.transcription.error("GeminiClient: \(http.statusCode) — \(message, privacy: .private)")
            throw TranscriptionError.network(message)
        }

        return try Self.extractText(from: data)
    }

    /// Extracts a short retry hint from a 429: Retry-After header or the
    /// google.rpc.RetryInfo "retryDelay": "2s" detail in the error body.
    static func retryDelaySeconds(from data: Data, headers: HTTPURLResponse) -> Double? {
        if let header = headers.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
            return seconds
        }
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        if let range = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) {
            let match = String(body[range])
            let digits = match.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber || $0 == "." })
            return Double(digits)
        }
        return nil
    }

    struct DeadlineExceeded: Error {}

    /// Races an operation against a hard wall-clock deadline.
    static func withDeadline<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DeadlineExceeded()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    deinit {
        session.invalidateAndCancel() // transient clients (key validation) must not leak (audit L33)
    }

    private func applyAuth(_ request: inout URLRequest) {
        // Header, never ?key= — query strings leak into logs and proxies.
        if let key = apiKey() {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    // MARK: - Response parsing (pure, tested)

    static func extractText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.network("unparseable_response")
        }
        if let feedback = json["promptFeedback"] as? [String: Any],
           feedback["blockReason"] != nil {
            throw TranscriptionError.safetyBlocked
        }
        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first else {
            throw TranscriptionError.network("no_candidates")
        }
        if let finish = first["finishReason"] as? String, finish == "SAFETY" {
            throw TranscriptionError.safetyBlocked
        }
        let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text
    }

    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}
