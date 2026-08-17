import Foundation

/// Result of a completed (or stopped) capture.
public struct AudioCaptureResult: Equatable, Sendable {
    public var framesWritten: Int64
    public var durationSeconds: Double
    /// Seconds-from-start positions where a device change may have left a seam.
    public var gapMarkers: [Double]

    public init(framesWritten: Int64, durationSeconds: Double, gapMarkers: [Double] = []) {
        self.framesWritten = framesWritten
        self.durationSeconds = durationSeconds
        self.gapMarkers = gapMarkers
    }
}

/// Seam for the coordinator so it can be tested headless with a fake recorder.
public protocol AudioCapturing: AnyObject {
    /// ~30Hz RMS level in 0…1, delivered on an arbitrary queue.
    var onLevel: ((Float) -> Void)? { get set }
    /// Fired when the input device changed mid-recording (informational).
    var onDeviceChange: ((String) -> Void)? { get set }
    /// Starts the engine and begins writing CAF to `url` immediately.
    func start(writingTo url: URL) throws
    /// Stops and finalizes the file. Safe to call once.
    func stop() -> AudioCaptureResult
}
