import XCTest
@testable import JotCore

/// The native smart transcription surface. Fixtures are real responses captured
/// from the live API on 2026-08-20, not hand-written guesses.
final class TranscriptionConfigTests: XCTestCase {

    /// THE test in this file.
    ///
    /// `{"mode":"smart","language_codes":["en-US"]}` returns VERBATIM output with
    /// HTTP 200 and no error — smart mode is silently disabled, and there is no
    /// runtime signal of any kind. The published example pairs them, so this is
    /// exactly how the regression would arrive: someone adds locale support, every
    /// dictation quietly stops being cleaned up, and nothing anywhere reports it.
    func testNeverSendsLanguageCodes() {
        for mode in GeminiClient.TranscriptionMode.allCases {
            for vocabulary in [[], ["Spanner"], ["Ammaar", "Kubernetes"]] {
                let config = GeminiClient.transcriptionConfig(mode: mode, customVocabulary: vocabulary)
                XCTAssertNil(config?["language_codes"],
                             "language_codes silently disables smart mode — \(mode), \(vocabulary)")
                XCTAssertNil(config?["languageCodes"], "camelCase spelling is the same landmine")
            }
        }
    }

    /// Verbatim is the server default: sending the field is byte-identical to
    /// omitting it, so we omit it and keep the request minimal.
    func testVerbatimOmitsConfigEntirely() {
        XCTAssertNil(GeminiClient.transcriptionConfig(mode: .verbatim, customVocabulary: []))
    }

    func testSmartCarriesModeAndVocabulary() {
        let config = GeminiClient.transcriptionConfig(mode: .smart, customVocabulary: ["Kubernetes"])
        XCTAssertEqual(config?["mode"] as? String, "smart")
        XCTAssertEqual(config?["custom_vocabulary"] as? [String], ["Kubernetes"])
    }

    /// Vocabulary must survive on the verbatim path too — it biases the
    /// recogniser, which is orthogonal to whether the model reformats.
    func testVerbatimStillCarriesVocabulary() {
        let config = GeminiClient.transcriptionConfig(mode: .verbatim, customVocabulary: ["Kubernetes"])
        XCTAssertEqual(config?["custom_vocabulary"] as? [String], ["Kubernetes"])
        XCTAssertNil(config?["mode"], "verbatim is the default; naming it buys nothing")
    }
}

final class InteractionsEnvelopeTests: XCTestCase {

    private func data(_ json: String) -> Data { json.data(using: .utf8)! }

    /// A real captured response, trimmed.
    func testParsesRealEnvelope() throws {
        let body = data("""
        {"id":"interaction-1","object":"interaction","model":"gemini-3.5-transcribe",
         "status":"completed","created":"2026-08-20T12:00:00Z",
         "steps":[{"type":"model_output","content":[{"type":"text","text":"Let's meet at 2pm."}]}],
         "usage":{"total_input_tokens":268,"total_output_tokens":0}}
        """)
        XCTAssertEqual(try GeminiClient.extractInteractionText(from: body), "Let's meet at 2pm.")
    }

    func testJoinsMultipleStepsAndTextItems() throws {
        let body = data("""
        {"status":"completed","steps":[
          {"type":"model_output","content":[{"type":"text","text":"one "},{"type":"text","text":"two "}]},
          {"type":"model_output","content":[{"type":"text","text":"three"}]}]}
        """)
        XCTAssertEqual(try GeminiClient.extractInteractionText(from: body), "one two three")
    }

    /// Non-model_output steps (tool calls, reasoning) must not leak into the
    /// text that gets typed at the user's cursor.
    func testIgnoresNonModelOutputSteps() throws {
        let body = data("""
        {"status":"completed","steps":[
          {"type":"tool_use","content":[{"type":"text","text":"SHOULD NOT APPEAR"}]},
          {"type":"model_output","content":[{"type":"text","text":"kept"}]}]}
        """)
        XCTAssertEqual(try GeminiClient.extractInteractionText(from: body), "kept")
    }

    /// Empty must come back as "" and NOT throw: the service owns the
    /// empty-transcript re-send and the coordinator classifies silence by audio
    /// energy. Throwing here would route a quiet dictation into the failure path
    /// and, for a short quiet hold, into discardSessionArtifacts().
    func testEmptyTextReturnsEmptyStringRatherThanThrowing() throws {
        let body = data("""
        {"status":"completed","steps":[{"type":"model_output","content":[]}]}
        """)
        XCTAssertEqual(try GeminiClient.extractInteractionText(from: body), "")
    }

    /// An unknown status is RETRYABLE on purpose. Under never-lose-words the safe
    /// direction on a string we have never seen is keeping the row queued, not
    /// marking the dictation permanently failed.
    func testUnknownStatusIsRetryable() {
        let body = data(#"{"status":"queued","steps":[]}"#)
        XCTAssertThrowsError(try GeminiClient.extractInteractionText(from: body)) { error in
            guard case TranscriptionError.network = error as? TranscriptionError ?? .timeout else {
                return XCTFail("unknown status must map to .network (retryable), got \(error)")
            }
        }
    }

    func testFailedWithSafetyDetailMapsToSafetyBlocked() {
        let error = GeminiClient.mapInteractionStatus(
            "failed", json: ["error": ["message": "Response blocked by safety filters"]]
        )
        XCTAssertEqual(error, .safetyBlocked)
    }

    func testFailedWithoutSafetyDetailIsRetryable() {
        let error = GeminiClient.mapInteractionStatus("failed", json: [:])
        guard case .network = error else {
            return XCTFail("a bare failure should stay retryable, got \(error)")
        }
    }

    /// The two endpoints do not share an error envelope: interactions
    /// array-wraps auth errors. Casting straight to [String: Any] yields nil and
    /// the user sees "http_400" instead of "API key not valid".
    func testErrorMessageParsesArrayWrappedEnvelope() {
        let wrapped = data(#"[{"error":{"code":400,"message":"API key not valid."}}]"#)
        XCTAssertEqual(GeminiClient.errorMessage(from: wrapped), "API key not valid.")

        let plain = data(#"{"error":{"code":400,"message":"API key not valid."}}"#)
        XCTAssertEqual(GeminiClient.errorMessage(from: plain), "API key not valid.")
    }

    /// interactions reports `code` as a String ("not_found") where
    /// generateContent reports an Int. We only read `message`, so this is a
    /// regression guard on that staying true.
    func testErrorMessageSurvivesStringCode() {
        let body = data(#"{"error":{"code":"not_found","message":"Model 'x' not found."}}"#)
        XCTAssertEqual(GeminiClient.errorMessage(from: body), "Model 'x' not found.")
    }
}
