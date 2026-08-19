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
    /// A graph built and prepared ahead of the key press, NOT started — no audio
    /// flows and no mic indicator until start(). Building it costs 75–135ms on a
    /// Bluetooth route (measured), which is exactly the window where the first
    /// words are lost, so it must never happen on the critical path.
    private var prewarmedDevice: AudioDeviceID?
    private var isPrewarmed = false
    /// Parked while stop() waits for the HAL's in-flight buffer to land.
    private var tailWaiter: CheckedContinuation<Void, Never>?
    private var writer: CAFWriter?
    /// The default input at session start — used to DETECT changes, never to pin.
    private var sessionDevice: AudioDeviceID?
    private var configObserver: NSObjectProtocol?

    private let queue = DispatchQueue(label: "com.ammaar.jot.audio.write", qos: .userInitiated)
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

    /// Build + prepare the capture graph during idle so the key press only pays
    /// engine.start(). Safe to call repeatedly; cheap when already warm.
    public func prewarm() {
        guard !isPrewarmed else { return }
        do {
            try buildEngine(reason: "prewarm", start: false)
            isPrewarmed = true
            prewarmedDevice = AudioDeviceQuery.defaultInputDevice()
        } catch {
            // Prewarm is an optimization, never a failure mode — the session's
            // own start() will build fresh and report any real problem.
            Log.audio.info("prewarm skipped: \(String(describing: error), privacy: .public)")
            tearDownEngine()
            isPrewarmed = false
        }
    }

    public func start(writingTo url: URL) throws {
        let startClock = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startClock.uptimeNanoseconds) / 1_000_000
            // Engine-start cost is the gap where speech can be lost — never a
            // mystery: Bluetooth routes cost far more than the built-in mic.
            Log.audio.info("capture start: \(ms, format: .fixed(precision: 1))ms on \(AudioInputDevices.currentDefaultName() ?? "unknown", privacy: .public)")
        }
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
        // Reuse the prepared graph unless the input device moved under us.
        if isPrewarmed, let engine, prewarmedDevice == sessionDevice {
            isPrewarmed = false
            do {
                try engine.start()
                observeConfigurationChanges(of: engine)
                Log.audio.info("AudioCaptureEngine: engine running (warm start)")
                return
            } catch {
                Log.audio.info("warm start failed — rebuilding: \(String(describing: error), privacy: .public)")
                tearDownEngine()
            }
        }
        isPrewarmed = false
        try buildAndStartEngine(reason: "start")
    }

    public func stop() async -> AudioCaptureResult {
        let alreadyStopped = withStateLock { stopped }

        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if !alreadyStopped {
            // The tap only ever delivers WHOLE buffers (~104ms on this hardware),
            // so tearing the engine down here discarded everything the HAL had
            // accumulated since the last callback — measurably the tail of the
            // user's last word, on every single recording (never-lose-words).
            // Wait for one more buffer to LAND: a signal, not a sleep, capped so
            // a dead engine can never stall finalize.
            if engine?.isRunning == true {
                let before = withStateLock { framesWritten }
                await awaitTailBuffer(timeoutSeconds: 0.16)
                let recovered = withStateLock { framesWritten } - before
                if recovered > 0 {
                    Log.audio.info("tail drained: +\(Double(recovered) / self.targetFormat.sampleRate * 1000, format: .fixed(precision: 0))ms of speech that used to be discarded")
                }
            }
            tearDownEngine()
            // Barrier on the write queue so every queued buffer lands before close.
            queue.sync {}
            // Only NOW refuse further buffers: setting this before the barrier is
            // what made the barrier a no-op for the tail it was meant to save.
            withStateLock { stopped = true }
            writer?.close()
        }

        let (frames, gaps, peak) = withStateLock { (framesWritten, gapMarkers, peakLevel) }
        return AudioCaptureResult(
            framesWritten: frames,
            durationSeconds: Double(frames) / targetFormat.sampleRate,
            gapMarkers: gaps,
            peakLevel: peak
        )
    }

    /// Resolves when the next buffer is written, or when the cap expires —
    /// whichever comes first. Never resumes twice: the continuation is cleared
    /// under the lock before it is resumed.
    private func awaitTailBuffer(timeoutSeconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            guard !stopped, tailWaiter == nil else {
                stateLock.unlock()
                continuation.resume()
                return
            }
            tailWaiter = continuation
            stateLock.unlock()
            let timeoutGuard = { [weak self] in self?.resumeTailWaiter() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                timeoutGuard()
            }
        }
    }

    /// NSLock cannot be locked across a suspension point; every async caller
    /// goes through this synchronous critical section instead.
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func resumeTailWaiter() {
        stateLock.lock()
        let waiter = tailWaiter
        tailWaiter = nil
        stateLock.unlock()
        waiter?.resume()
    }

    // MARK: - Engine plumbing

    private func buildAndStartEngine(reason: String) throws {
        try buildEngine(reason: reason, start: true)
    }

    private func buildEngine(reason: String, start shouldStart: Bool) throws {
        let t0 = DispatchTime.now()
        func ms(_ from: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000
        }
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
        guard shouldStart else {
            Log.audio.info("AudioCaptureEngine: graph prepared in \(ms(t0), format: .fixed(precision: 1))ms (\(reason, privacy: .public), not started)")
            return
        }
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineStart(String(describing: error))
        }

        observeConfigurationChanges(of: engine)
        Log.audio.info("AudioCaptureEngine: engine running (\(reason, privacy: .public); hw=\(Int(hwFormat.sampleRate))Hz/\(hwFormat.channelCount)ch, device=\(self.sessionDevice.map(String.init) ?? "default", privacy: .public))")
    }

    /// Observe THIS engine only. Rebuilding creates a new engine which posts its
    /// own configuration-change on start — observing all engines (object: nil)
    /// created an infinite rebuild loop that captured zero frames.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func tearDownEngine() {
        // A stop() parked on the tail must never outlive the engine.
        resumeTailWaiter()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        isPrewarmed = false
        prewarmedDevice = nil
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
                // A stop() waiting on the tail can finish now — this buffer is
                // the audio that used to be thrown away.
                self.resumeTailWaiter()
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
