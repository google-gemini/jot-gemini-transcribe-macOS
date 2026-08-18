import AVFoundation
import Foundation

/// Incremental CAF/LPCM writer.
///
/// CAF is the crash-safe choice: chunk sizes may be written as "growing", so a file
/// interrupted by crash or kill -9 remains playable — WAV needs its RIFF header
/// rewritten at the end and M4A is unrecoverable (Apple forums 720691/766774).
///
/// Note on fsync: AVAudioFile doesn't expose its descriptor. That's acceptable —
/// data written by a process survives that process's death (it lives in the kernel
/// page cache); fsync would only add power-loss protection, which no shipping
/// dictation app provides either.
final class CAFWriter {
    private var file: AVAudioFile?

    init(url: URL, format: AVAudioFormat) throws {
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try file?.write(from: buffer)
    }

    /// Releases the file (AVAudioFile finalizes on deinit). Safe to call once.
    func close() {
        file = nil
    }
}
