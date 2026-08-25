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

import AVFoundation
import Foundation

/// CAF → FLAC transcode at key-up. Measured: 5ms/14ms/231ms for 5s/30s/10min —
/// invisible inside the latency budget.
public enum FLACEncoder {
    public struct Output: Sendable {
        public let url: URL
        public let byteCount: Int
        public let encodeSeconds: Double
    }

    public enum EncodeError: Error {
        case readFailed(String)
        case writeFailed(String)
    }

    public static func encode(cafURL: URL, flacURL: URL) throws -> Output {
        let started = Date()
        try? FileManager.default.removeItem(at: flacURL)

        let reader: AVAudioFile
        do {
            reader = try AVAudioFile(forReading: cafURL, commonFormat: .pcmFormatInt16, interleaved: true)
        } catch {
            throw EncodeError.readFailed(String(describing: error))
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: reader.processingFormat.sampleRate,
            AVNumberOfChannelsKey: reader.processingFormat.channelCount,
        ]
        do {
            let writer = try AVAudioFile(
                forWriting: flacURL, settings: settings,
                commonFormat: .pcmFormatInt16, interleaved: true
            )
            let chunk = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 65_536)!
            // read(into:) can throw a spurious nilError at EOF with an Int16 client
            // format — guard on framePosition instead (probed on macOS 26).
            while reader.framePosition < reader.length {
                try reader.read(into: chunk)
                if chunk.frameLength == 0 { break }
                try writer.write(from: chunk)
            }
        } catch {
            throw EncodeError.writeFailed(String(describing: error))
        }

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: flacURL.path))?[.size] as? Int) ?? 0
        return Output(url: flacURL, byteCount: bytes, encodeSeconds: Date().timeIntervalSince(started))
    }
}
