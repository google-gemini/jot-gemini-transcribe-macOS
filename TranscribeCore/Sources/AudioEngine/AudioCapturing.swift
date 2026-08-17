import Foundation

/// Result of a completed (or stopped) capture.
public struct AudioCaptureResult: Equatable, Sendable {
    public var framesWritten: Int64
    public var durationSeconds: Double
    /// Seconds-from-start positions where a device change may have left a seam.
    public var gapMarkers: [Double]
    /// Peak metered level (same 0…1 scale as `onLevel`). Distinguishes "held the
    /// key in silence" from "spoke but transcription came back empty" (F9a vs F9b).
    public var peakLevel: Float

    public init(framesWritten: Int64, durationSeconds: Double, gapMarkers: [Double] = [], peakLevel: Float = 1.0) {
        self.framesWritten = framesWritten
        self.durationSeconds = durationSeconds
        self.gapMarkers = gapMarkers
        self.peakLevel = peakLevel
    }
}

/// Seam for the coordinator so it can be tested headless with a fake recorder.
public protocol AudioCapturing: AnyObject {
    /// ~30Hz RMS level in 0…1, delivered on an arbitrary queue.
    var onLevel: ((Float) -> Void)? { get set }
    /// Fired when the input device changed mid-recording (informational).
    var onDeviceChange: ((String) -> Void)? { get set }
    /// Fired once when disk writes fail persistently (F22) — captured audio up to
    /// that point is preserved; the coordinator should finalize early.
    var onWriteFailure: (() -> Void)? { get set }
    /// Starts the engine and begins writing CAF to `url` immediately.
    func start(writingTo url: URL) throws
    /// Stops and finalizes the file. Safe to call once.
    func stop() -> AudioCaptureResult
}
