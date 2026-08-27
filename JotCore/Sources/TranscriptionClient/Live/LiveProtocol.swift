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

/// What the server said. Deliberately small: everything the Live API sends that
/// Jot does not act on becomes `nil` rather than a case, so an API that grows new
/// message types does not start throwing in the middle of someone's dictation.
public enum LiveEvent: Equatable, Sendable {
    /// The credential was accepted and the session is configured. Audio sent
    /// before this arrives is buffered, not lost.
    case setupComplete
    /// A speculative hypothesis, replaced by later ones. **Display only.**
    /// This must never reach the cursor, History, or `rawTranscript`.
    case partial(String)
    /// Authoritative text for a finished speech segment. In SMART mode this is
    /// already cleaned and formatted.
    case final(String)
    /// The server is closing the session — the 10-minute cap, or its own reasons.
    case goAway
    /// An error envelope. Terminal for the session.
    case failed(String)
}

/// Everything that varies per session.
public struct LiveSetup: Equatable, Sendable {
    public var model: String
    public var smart: Bool
    public var customVocabulary: [String]

    public init(model: String = "gemini-3.5-transcribe-live",
                smart: Bool = true,
                customVocabulary: [String] = []) {
        self.model = model
        self.smart = smart
        self.customVocabulary = customVocabulary
    }
}

/// Frame construction and decoding for the Live API WebSocket, as pure functions
/// over `Data` so every one of them is testable without a socket.
public enum LiveProtocol {

    public static let audioMIME = "audio/pcm;rate=16000"

    /// The ONLY place a live setup frame is constructed.
    ///
    /// **NEVER add `languageCodes` here without probing it first.** On the
    /// interactions endpoint, sending `language_codes` alongside `mode: smart`
    /// returns VERBATIM output with HTTP 200, no error, and no runtime signal of
    /// any kind — the formatting silently stops happening and nothing anywhere
    /// says so. The live API takes both fields in the same object, and the
    /// published example pairs them, which is precisely how that bug would ship
    /// a second time. Omitting the field is also what the docs prescribe for
    /// automatic language detection, so there is no cost to leaving it out.
    ///
    /// Manual VAD is not optional here: Jot decides turn boundaries from the
    /// hotkey, so server-side voice detection would cut turns in the middle of
    /// someone pausing to think.
    public static func setupFrame(_ setup: LiveSetup) -> Data {
        var transcription: [String: Any] = ["mode": setup.smart ? "SMART" : "VERBATIM"]
        if !setup.customVocabulary.isEmpty {
            transcription["customVocabulary"] = setup.customVocabulary
        }
        let frame: [String: Any] = [
            "setup": [
                "model": "models/\(setup.model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
                "realtimeInputConfig": [
                    "automaticActivityDetection": ["disabled": true],
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    public static func audioFrame(_ pcm: Data) -> Data {
        let frame: [String: Any] = [
            "realtimeInput": [
                "audio": ["data": pcm.base64EncodedString(), "mimeType": audioMIME],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    public static func activityStartFrame() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["realtimeInput": ["activityStart": [:] as [String: Any]]])) ?? Data()
    }

    public static func activityEndFrame() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["realtimeInput": ["activityEnd": [:] as [String: Any]]])) ?? Data()
    }

    /// Decodes one server frame.
    ///
    /// Returns nil for anything unrecognised. That is deliberate: an unknown
    /// message is not a reason to tear down a session that is otherwise
    /// transcribing someone's sentence, and the fallback to the batch path is
    /// reserved for failures that actually cost words.
    ///
    /// Order matters. `interimInputTranscription` is checked before
    /// `inputTranscription` because a single frame may carry both, and treating
    /// an interim as final is the one mistake in this file that puts speculative
    /// text on the user's cursor.
    public static func decode(_ data: Data) -> LiveEvent? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if root["setupComplete"] != nil || root["setup_complete"] != nil {
            return .setupComplete
        }
        if let error = root["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown live error"
            return .failed(message)
        }
        let content = (root["serverContent"] ?? root["server_content"]) as? [String: Any]
        if let content {
            if content["goAway"] != nil || content["go_away"] != nil { return .goAway }
            if let text = transcriptText(content, "interimInputTranscription", "interim_input_transcription") {
                return .partial(text)
            }
            if let text = transcriptText(content, "inputTranscription", "input_transcription") {
                return .final(text)
            }
        }
        if root["goAway"] != nil || root["go_away"] != nil { return .goAway }
        return nil
    }

    /// Accepts both camelCase and snake_case because the two documented clients
    /// disagree about which the socket speaks, and guessing wrong here would look
    /// exactly like a model that transcribes nothing.
    private static func transcriptText(_ content: [String: Any], _ camel: String, _ snake: String) -> String? {
        guard let node = (content[camel] ?? content[snake]) as? [String: Any],
              let text = node["text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }
}
