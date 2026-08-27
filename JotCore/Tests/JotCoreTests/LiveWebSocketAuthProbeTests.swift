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

import XCTest
@testable import JotCore

/// Answers ONE question, and it gates the whole live-transcription feature:
///
///   **Does the Live API WebSocket handshake accept `x-goog-api-key` as a header,
///   or is `?key=` in the URL the only way in?**
///
/// It matters because `GeminiClient.swift` states the rule the rest of the app
/// follows — "Header, never ?key= — query strings leak into logs and proxies" —
/// and that threat model is not hypothetical here: this repo is developed on a
/// machine running a TLS-intercepting corporate proxy, which terminates the
/// connection and writes the request line, query string included, to a retained
/// log. `?key=<long-lived Gemini key>` there means the user's personal API key
/// lands in their employer's proxy logs on every single dictation.
///
/// The published docs only ever show `?key=`. Undocumented is not the same as
/// unsupported — the same front end accepts the header on every REST route — so
/// this is an empirical question, and one run answers it.
///
/// Two arms on purpose. Without the control, a red header arm is ambiguous: bad
/// auth, or a malformed setup frame? The control uses the documented `?key=`
/// form with a byte-identical frame, so:
///
///   control PASS + header PASS → use the header. Rule preserved, ship it.
///   control PASS + header FAIL → the header is genuinely rejected. Fall back to
///                                an ephemeral token so only a short-lived
///                                credential is ever in a URL.
///   control FAIL              → the frame, model name, or network is wrong.
///                                Says nothing about auth; fix that first.
///
/// Opt in explicitly; never runs in a normal build:
///
///   JOT_LIVE_PROBE=1 GEMINI_API_KEY=... ./scripts/test.sh --filter LiveWebSocketAuthProbe
final class LiveWebSocketAuthProbeTests: XCTestCase {

    private static let model = "gemini-3.5-transcribe-live"
    private static let host =
        "generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private func requireKey() throws -> String {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "live probe not opted in")
        try XCTSkipUnless(env["GEMINI_API_KEY"] != nil, "GEMINI_API_KEY required for the live probe")
        return env["GEMINI_API_KEY"]!
    }

    /// Byte-identical between the two arms so the ONLY difference is where the
    /// credential goes. Manual VAD, because that is the shape Jot will actually
    /// use — hold-to-talk sends activityStart/activityEnd itself.
    ///
    /// NOTE: `languageCodes` is deliberately absent rather than `[]`. On the
    /// interactions endpoint, sending `language_codes` alongside smart mode
    /// silently degraded output to verbatim — HTTP 200, no error, no signal. That
    /// trap is documented at the `transcriptionConfig` chokepoint in GeminiClient.
    /// Until the same pairing is proven safe here, this probe does not send it.
    private func setupFrame() -> Data {
        let frame: [String: Any] = [
            "setup": [
                "model": "models/\(Self.model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": ["mode": "SMART"],
                "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: frame)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Fail fast rather than parking: a probe that waits for connectivity
        // reports a timeout instead of the answer we came for.
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }

    private enum Outcome {
        case setupComplete(String)
        /// The server answered and refused the credential. This is a real answer.
        case authRejected(String)
        /// The connection never got far enough to say anything about auth — a
        /// timeout, a dropped upgrade, a proxy mangling the handshake. Reporting
        /// this as "header auth rejected" is how a probe lies to you: the first
        /// run of this suite did exactly that, and contradicted the second.
        case transportFailed(String)
    }

    /// Opens the socket, sends the setup frame, and reports the first thing the
    /// server says back. `setupComplete` means the credential was accepted.
    private func handshake(request: URLRequest) async -> Outcome {
        let session = makeSession()
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        do {
            try await task.send(.data(setupFrame()))
            let message = try await task.receive()
            let text: String
            switch message {
            case .data(let d): text = String(data: d, encoding: .utf8) ?? "<\(d.count) bytes>"
            case .string(let s): text = s
            @unknown default: text = "<unknown frame>"
            }
            // The server acknowledges a good setup with setupComplete. Anything
            // else on the first frame is an error envelope.
            if text.contains("setupComplete") || text.contains("setup_complete") {
                return .setupComplete(String(text.prefix(300)))
            }
            return .authRejected(String(text.prefix(300)))
        } catch {
            // Separate "the server said no" from "we never reached the server".
            // A failed WS upgrade carries the HTTP response, so a 401/403 is
            // visible and unambiguous; URLError transport codes are not about auth.
            if let http = task.response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .authRejected("HTTP \(http.statusCode) on upgrade")
                }
                return .transportFailed("HTTP \(http.statusCode) on upgrade — not an auth code")
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                     .notConnectedToInternet, .secureConnectionFailed,
                     .cannotFindHost, .dnsLookupFailed:
                    return .transportFailed("\(urlError.code): \(urlError.localizedDescription)")
                default:
                    return .transportFailed("URLError \(urlError.code): \(urlError.localizedDescription)")
                }
            }
            return .transportFailed("\(error)")
        }
    }

    /// CONTROL — the documented form. Proves the frame, model name and network
    /// are good, so the header arm's result means something.
    func testControlQueryParamKeyIsAccepted() async throws {
        let key = try requireKey()
        let url = URL(string: "wss://\(Self.host)?key=\(key)")!
        let outcome = await handshake(request: URLRequest(url: url))

        switch outcome {
        case .setupComplete(let ack):
            print("[probe] CONTROL (?key=) → setupComplete. \(ack)")
        case .authRejected(let why):
            XCTFail("""
                CONTROL ARM FAILED — the documented ?key= form was rejected: \(why)
                This says NOTHING about header auth. The setup frame or the model name \
                (\(Self.model)) is wrong. Fix this before reading the header arm.
                """)
        case .transportFailed(let why):
            throw XCTSkip("control arm could not reach the server (\(why)) — rerun; this is not a result")
        }
    }

    /// THE QUESTION. A pass here means Jot can keep its no-keys-in-URLs rule.
    ///
    /// Not `XCTFail` on rejection: a documented-only-one-way API declining an
    /// undocumented alternative is information, not a broken build. The whole
    /// point is to learn which branch of the design to take.
    func testApiKeyHeaderIsAcceptedOnHandshake() async throws {
        let key = try requireKey()
        var request = URLRequest(url: URL(string: "wss://\(Self.host)")!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let outcome = await handshake(request: request)

        switch outcome {
        case .setupComplete(let ack):
            print("""
                [probe] HEADER (x-goog-api-key) → setupComplete. \(ack)
                [probe] VERDICT: header auth WORKS. Use it — no credential in any URL,
                [probe]          and the GeminiClient rule holds for the live path too.
                """)
        case .transportFailed(let why):
            throw XCTSkip("""
                HEADER ARM INCONCLUSIVE — never reached the server: \(why)
                This is NOT evidence against header auth. Rerun, and if it only fails on the \
                corporate network, the proxy is mangling the upgrade — a different problem.
                """)
        case .authRejected(let why):
            print("""
                [probe] HEADER (x-goog-api-key) → rejected by the server: \(why)
                [probe] VERDICT: header auth is NOT accepted on the WS handshake.
                [probe]          Do not fall back to ?key=<long-lived key>. Mint an
                [probe]          ephemeral token over header-authenticated REST and put
                [probe]          only that short-lived token in the URL.
                """)
        }
    }

    /// Run both arms on a phone tether as well as the corporate network. If the
    /// header arm passes off-corp and fails on-corp, the proxy is stripping or
    /// mangling the upgrade request — a different problem from server-side auth,
    /// and one worth knowing about before any of this ships.
    func testProbeGuidanceIsRecorded() throws {
        _ = try requireKey()
        print("[probe] Run this suite twice: once on the corporate network, once tethered.")
    }
}
