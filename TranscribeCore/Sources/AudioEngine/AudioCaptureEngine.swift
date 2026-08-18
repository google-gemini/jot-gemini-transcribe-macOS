import AVFoundation
import Accelerate
import CoreAudio
import Foundation

/// The crash-safe recorder.
///
/// Invariants (docs/design/product-reliability.md — never-lose-words):
///  - CAF/LPCM written incrementally from the first buffer; a `kill -9` at any
///    moment leaves a playable file (CAF needs no header finalization).
///  - Device policy: record on the system default input. Pinning via
///    kAudioOutputUnitProperty_CurrentDevice or AUAudioUnit.setDeviceID leaves the
///    engine "running" with a dead tap (probed on macOS 26 — zero frames both
///    routes), so mid-session device changes are handled by rebuild + gap marker
///    instead (Wispr behavior). True pinning is a v1.x investigation (raw AUHAL).
///  - Zero frames captured is a detectable error state, never an empty transcript.
public final class AudioCaptureEngine: AudioCapturing {
    public var onLevel: ((Float) -> Void)?
    public var onDeviceChange: ((String) -> Void)?
    public var onWriteFailure: (() -> Void)?
    public var onEngineDied: ((String) -> Void)?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var writer: CAFWriter?
    /// The default input at session start — used to DETECT changes, never to pin.
    private var sessionDevice: AudioDeviceID?
    private var configObserver: NSObjectProtocol?

    private let queue = DispatchQueue(label: "com.google.transcribe.audio.write", qos: .userInitiated)
    private let stateLock = NSLock()
    private var framesWritten: Int64 = 0
    private var stopped = false
    private var startedAt: Date?
    private var gapMarkers: [Double] = []
    /// Circuit breaker: a config-change storm must never eat a session
    /// (the M2 field bug: rebuild → notification → rebuild, zero frames captured).
    private var rebuildCount = 0
    private let maxRebuildsPerSession = 5
    /// F22: sustained write failures (disk full) surface instead of silently
    /// eating audio while the level meter keeps dancing.
    private var consecutiveWriteFailures = 0
    private var writeFailureReported = false

    // Level metering (throttled to ~30Hz)
    private var levelAccumulator: Float = 0
    private var levelSampleCount = 0
    private var peakLevel: Float = 0

    public init() {}

    // MARK: - Lifecycle

    public func start(writingTo url: URL) throws {
        stateLock.lock()
        framesWritten = 0
        stopped = false
        gapMarkers = []
        startedAt = Date()
        peakLevel = 0
        stateLock.unlock()

        writer = try CAFWriter(url: url, format: targetFormat)
        sessionDevice = AudioDeviceQuery.defaultInputDevice()
        rebuildCount = 0
        try buildAndStartEngine(reason: "start")
    }

    public func stop() -> AudioCaptureResult {
        stateLock.lock()
        let alreadyStopped = stopped
        stopped = true
        stateLock.unlock()

        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if !alreadyStopped {
            tearDownEngine()
            // Barrier on the write queue so every queued buffer lands before close.
            queue.sync {}
            writer?.close()
        }

        stateLock.lock()
        let frames = framesWritten
        let gaps = gapMarkers
        let peak = peakLevel
        stateLock.unlock()
        return AudioCaptureResult(
            framesWritten: frames,
            durationSeconds: Double(frames) / targetFormat.sampleRate,
            gapMarkers: gaps,
            peakLevel: peak
        )
    }

    // MARK: - Engine plumbing

    private func buildAndStartEngine(reason: String) throws {
        tearDownEngine()

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        // Tap at the hardware format; conversion to 16k mono happens on our queue.
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        guard let converter else { throw CaptureError.converterUnavailable }
        self.converter = converter

        // 1024-frame buffers ⇒ level updates at ~47Hz (4096 gave a sluggish ~12Hz
        // waveform); the write path is unaffected — buffers just arrive smaller.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.ingest(buffer, hwRate: hwFormat.sampleRate)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStart(String(describing: error))
        }

        // Observe THIS engine only. Rebuilding creates a new engine which posts its
        // own configuration-change on start — observing all engines (object: nil)
        // created an infinite rebuild loop that captured zero frames.
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        Log.audio.info("AudioCaptureEngine: engine running (\(reason, privacy: .public); hw=\(Int(hwFormat.sampleRate))Hz/\(hwFormat.channelCount)ch, device=\(self.sessionDevice.map(String.init) ?? "default", privacy: .public))")
    }

    private func tearDownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
    }

    private func handleConfigurationChange() {
        stateLock.lock()
        let isStopped = stopped
        let frames = framesWritten
        stateLock.unlock()
        guard !isStopped else { return }

        // The notification means "the engine stopped because its configuration
        // changed". If our engine is in fact still running (spurious/self-induced
        // notification), there is nothing to rebuild.
        if let engine, engine.isRunning {
            Log.audio.debug("AudioCaptureEngine: config-change while engine still running — ignored")
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            // stop() may have completed while this rebuild was queued (audit L2).
            self.stateLock.lock()
            let stoppedNow = self.stopped
            self.stateLock.unlock()
            guard !stoppedNow else { return }
            self.rebuildCount += 1
            guard self.rebuildCount <= self.maxRebuildsPerSession else {
                Log.audio.error("AudioCaptureEngine: rebuild circuit breaker tripped (\(self.rebuildCount)) — leaving engine down; captured audio is preserved")
                self.onEngineDied?("Mic kept reconnecting")
                return
            }
            let seam = Double(frames) / self.targetFormat.sampleRate
            let newDefault = AudioDeviceQuery.defaultInputDevice()
            if newDefault != self.sessionDevice {
                // Mic switched mid-recording (AirPods connected/died): mark the seam,
                // continue on the new default, keep appending to the same CAF.
                self.sessionDevice = newDefault
                self.stateLock.lock()
                self.gapMarkers.append(seam)
                self.stateLock.unlock()
                self.onDeviceChange?("Mic changed — kept recording")
                Log.audio.warning("AudioCaptureEngine: input device changed at \(seam, format: .fixed(precision: 2))s — continuing on new default")
            } else {
                Log.audio.info("AudioCaptureEngine: config change on same device — rebuilding")
            }
            do {
                try self.buildAndStartEngine(reason: "config-change")
            } catch {
                Log.audio.error("AudioCaptureEngine: rebuild failed: \(error)")
                self.onEngineDied?("Mic disconnected")
            }
        }
    }

    // MARK: - Buffer path (audio thread → write queue)

    private func ingest(_ buffer: AVAudioPCMBuffer, hwRate: Double) {
        meterLevel(of: buffer)
        queue.async { [weak self] in
            guard let self, let converter = self.converter, let writer = self.writer else { return }
            self.stateLock.lock()
            let isStopped = self.stopped
            self.stateLock.unlock()
            guard !isStopped else { return }

            let ratio = self.targetFormat.sampleRate / hwRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return }

            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let error {
                Log.audio.error("AudioCaptureEngine: convert failed: \(error)")
                return
            }
            guard out.frameLength > 0 else { return }
            do {
                try writer.write(out)
                self.stateLock.lock()
                self.framesWritten += Int64(out.frameLength)
                self.consecutiveWriteFailures = 0
                self.stateLock.unlock()
            } catch {
                Log.audio.error("AudioCaptureEngine: CAF write failed: \(error)")
                self.stateLock.lock()
                self.consecutiveWriteFailures += 1
                let shouldReport = self.consecutiveWriteFailures >= 15 && !self.writeFailureReported
                if shouldReport { self.writeFailureReported = true }
                self.stateLock.unlock()
                if shouldReport {
                    self.onWriteFailure?() // ~0.3s of sustained failure (F22)
                }
            }
        }
    }

    private func meterLevel(of buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        levelAccumulator += rms
        levelSampleCount += 1
        // Compressive curve: quiet speech lands mid-range instead of hugging the
        // floor, loud speech saturates gracefully — the bars feel ALIVE.
        let averageRMS = levelAccumulator / Float(levelSampleCount)
        let level = min(1, pow(min(averageRMS * 11, 1), 0.65))
        levelAccumulator = 0
        levelSampleCount = 0
        stateLock.lock()
        peakLevel = max(peakLevel, level)
        stateLock.unlock()
        onLevel?(level)
    }

    public enum CaptureError: Error, Equatable {
        case noInputDevice
        case converterUnavailable
        case engineStart(String)
    }
}

// MARK: - CoreAudio device helpers

enum AudioDeviceQuery {
    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    // NOTE: device *pinning* (kAudioOutputUnitProperty_CurrentDevice or
    // AUAudioUnit.setDeviceID on the input node) was probed on macOS 26 and leaves
    // the engine running with a silent tap — do not reintroduce it on AVAudioEngine.
}
