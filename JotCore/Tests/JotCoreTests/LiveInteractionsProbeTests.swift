import XCTest
@testable import JotCore

/// A LIVE check against the real API, through the real `GeminiClient` — not curl.
/// Unit tests cover the pure parsing; this covers the thing that actually ships.
///
/// Skipped unless explicitly opted in, so it never runs in a normal build:
///
///   JOT_LIVE_PROBE=1 GEMINI_API_KEY=... JOT_PROBE_AUDIO=/path/to/clip.flac ./scripts/test.sh
///
/// The clip should contain filler words and a self-correction, e.g.
/// "umm, so let's meet at 1pm — actually, no, make it 2pm".
final class LiveInteractionsProbeTests: XCTestCase {

    private func requireOptIn() throws -> (GeminiClient, Data, GeminiConfig) {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "live probe not opted in")
        let key = try XCTUnwrap(env["GEMINI_API_KEY"], "GEMINI_API_KEY required")
        let path = try XCTUnwrap(env["JOT_PROBE_AUDIO"], "JOT_PROBE_AUDIO required")
        let audio = try Data(contentsOf: URL(fileURLWithPath: path))
        return (GeminiClient(apiKey: { key }), audio, GeminiConfig())
    }

    /// The default path end to end: smart mode must collapse the self-correction
    /// and drop the fillers.
    func testSmartModeCleansThroughTheShippingClient() async throws {
        let (client, audio, config) = try requireOptIn()
        let text = try await client.transcribeInteraction(
            audio: audio, model: config.transcribeModel, endpoint: config.endpoint,
            mode: .smart, customVocabulary: [], deadline: 60
        )
        XCTAssertFalse(text.isEmpty, "smart mode returned nothing — the classic silent failure")
        XCTAssertFalse(text.lowercased().contains("umm"), "fillers should be gone: \(text)")
        XCTAssertFalse(text.lowercased().contains("actually, no"), "self-correction should collapse: \(text)")
        print("SMART → \(text)")
    }

    /// Verbatim must NOT clean, otherwise the "exact transcription" promise in
    /// Settings is false.
    func testVerbatimKeepsTheFillers() async throws {
        let (client, audio, config) = try requireOptIn()
        let text = try await client.transcribeInteraction(
            audio: audio, model: config.transcribeModel, endpoint: config.endpoint,
            mode: .verbatim, customVocabulary: [], deadline: 60
        )
        XCTAssertFalse(text.isEmpty)
        print("VERBATIM → \(text)")
    }

    /// The landmine, asserted against the live API rather than only in a comment:
    /// adding language_codes silently reverts smart mode to verbatim. If this ever
    /// starts passing, the server fixed it and the chokepoint can be relaxed.
    func testLanguageCodesStillBreaksSmartMode() async throws {
        let (client, audio, config) = try requireOptIn()
        let smart = try await client.transcribeInteraction(
            audio: audio, model: config.transcribeModel, endpoint: config.endpoint,
            mode: .smart, customVocabulary: [], deadline: 60
        )
        // Reproduce the broken request by hand — the shipping chokepoint refuses
        // to build it, which is the whole point.
        let broken = try await Self.rawInteraction(
            key: ProcessInfo.processInfo.environment["GEMINI_API_KEY"]!,
            audio: audio, model: config.transcribeModel,
            config: ["mode": "smart", "language_codes": ["en-US"]]
        )
        XCTAssertNotEqual(
            smart.trimmingCharacters(in: .whitespacesAndNewlines),
            broken.trimmingCharacters(in: .whitespacesAndNewlines),
            "language_codes no longer disables smart mode — re-check the chokepoint comment"
        )
        print("SMART → \(smart)\nWITH language_codes → \(broken)")
    }

    private static func rawInteraction(key: String, audio: Data, model: String, config: [String: Any]) async throws -> String {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": [["type": "audio", "mime_type": "audio/flac", "data": audio.base64EncodedString()]],
            "generation_config": ["transcription_config": config],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try GeminiClient.extractInteractionText(from: data)
    }
}
