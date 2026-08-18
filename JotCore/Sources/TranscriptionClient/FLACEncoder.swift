import AVFoundation
import Foundation

/// CAF → FLAC transcode at key-up. Measured: 5ms/14ms/231ms for 5s/30s/10min —
/// invisible inside the latency budget (docs/design/endpoint-probe-results.md).
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
