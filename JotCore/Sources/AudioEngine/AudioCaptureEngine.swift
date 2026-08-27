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

    /// Set once per session in `start`, read only on the write queue. Never
    /// reassigned mid-session — see the note on `AudioCapturing.start`.
    private var pcmSink: (@Sendable (Data) -> Void)?
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
    /// The authoritative peak: computed on the WRITE queue from the converted
    /// buffer, which is 16kHz mono Int16 by construction. No hardware change, no
    /// voice-processing format, and no aggregate device can ever blind it — which
    /// is what makes the tap-path metering failure survivable rather than fatal.
    private var writtenPeakLevel: Float = 0
    private var meteringDidRun = false
    private var meteringBlindReported = false
    private var writtenPeakDidRun = false
    /// Phase 0 instrumentation: engine.start() returning is NOT when audio starts
    /// flowing. The gap between them is where the first words go, and on a
    /// Bluetooth route it is a different order of magnitude than on the built-in
    /// mic — which is why any watchdog built on it must be per-transport.
    private var startedClock: DispatchTime?
    private var firstBufferLogged = false

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

    public func start(writingTo url: URL, pcmSink pcmSink0: (@Sendable (Data) -> Void)?) throws {
        let startClock = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startClock.uptimeNanoseconds) / 1_000_000
            // Engine-start cost is the gap where speech can be lost — never a
            // mystery: Bluetooth routes cost far more than the built-in mic.
            Log.audio.info("capture start: \(ms, format: .fixed(precision: 1))ms on \(AudioInputDevices.currentDefaultName() ?? "unknown", privacy: .public)")
        }
        stateLock.lock()
        pcmSink = pcmSink0
        framesWritten = 0
        stopped = false
        gapMarkers = []
        startedAt = Date()
        peakLevel = 0
        writtenPeakLevel = 0
        meteringDidRun = false
        writtenPeakDidRun = false
        firstBufferLogged = false
        stateLock.unlock()
        startedClock = startClock

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
            withStateLock { stopped = true; pcmSink = nil }
            writer?.close()
        }

        let (frames, gaps, peak, writtenPeak, metered, written) = withStateLock {
            (framesWritten, gapMarkers, peakLevel, writtenPeakLevel, meteringDidRun, writtenPeakDidRun)
        }
        // Migration evidence: gate on the tap peak, log both, flip only when real
        // sessions say they agree. The 16kHz resample drops everything above 8kHz
        // so they should track closely — but "should" is not how you move a
        // threshold that discards recordings.
        if metered, written {
            Log.audio.info("peak tap=\(peak, format: .fixed(precision: 3)) written=\(writtenPeak, format: .fixed(precision: 3)) delta=\(writtenPeak - peak, format: .fixed(precision: 3))")
        }
        // Tap metering blind (a format we could not read) but audio on disk: the
        // written peak IS the measurement. Only with neither is loudness unknown.
        let effectivePeak = metered ? peak : writtenPeak
        return AudioCaptureResult(
            framesWritten: frames,
            durationSeconds: Double(frames) / targetFormat.sampleRate,
            gapMarkers: gaps,
            peakLevel: effectivePeak,
            writtenPeakLevel: writtenPeak,
            peakIsTrustworthy: metered || written
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

        // NOTE: bufferSize is a REQUEST, and AVAudioNode documents the supported
        // range as [100, 400]ms — 1024 frames is silently clamped, so buffers
        // really arrive at ~10Hz, not the ~47Hz this comment used to claim
        // (docs/design/latency-audit-2026-08-19.md:53). Every threshold that
        // watches this stream has ~100ms of resolution, no more.
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

    /// The one place a converted buffer becomes wire bytes.
    ///
    /// It is a named function rather than two lines at the call site because the
    /// live path's safety check is arithmetic on its output: a stream may only be
    /// promoted to the real transcript when the bytes the socket accepted equal
    /// `framesWritten * 2`. If that identity is wrong, a truncated transcript is
    /// indistinguishable from a complete one, gets written to `rawTranscript`,
    /// and under "Never keep audio" the recording is deleted behind it. So the
    /// arithmetic gets a test, not a comment.
    ///
    /// Returns nil rather than empty `Data` when the buffer is not Int16 — an
    /// empty chunk is a legitimate value that would silently satisfy the check.
    static func pcmBytes(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.int16ChannelData else { return nil }
        // targetFormat is mono and interleaved, so channel 0 is the whole thing
        // in one contiguous block, and 2 is sizeof(Int16).
        return Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, hwRate: Double) {
        logFirstBufferIfNeeded(buffer)
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
            self.recordWrittenPeak(out)
            do {
                try writer.write(out)
                self.stateLock.lock()
                self.framesWritten += Int64(out.frameLength)
                self.consecutiveWriteFailures = 0
                self.stateLock.unlock()
                // A stop() waiting on the tail can finish now — this buffer is
                // the audio that used to be thrown away.
                self.resumeTailWaiter()
                // Strictly last, and never under stateLock. Ahead of the waiter it
                // would add the sink's cost to every finalize; inside the lock it
                // deadlocks the moment the sink touches anything that takes it.
                // `out` is interleaved mono Int16, so channel 0 is one contiguous
                // block and frameLength * 2 is the exact byte count.
                if let sink = self.pcmSink, let bytes = Self.pcmBytes(from: out) {
                    sink(bytes)
                }
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

    /// Drives the waveform, and (for now) the peak the coordinator gates on.
    ///
    /// This used to read `floatChannelData?[0]` and SILENTLY RETURN for anything
    /// else. Since `peakLevel` fed the discard gate, any format that wasn't
    /// Float32 — voice processing above all — would have left the peak at 0 and
    /// destroyed every recording as "silence". It now reads Int16 too and, when
    /// it genuinely cannot read a buffer, says so exactly once instead of
    /// pretending the room was quiet.
    private func meterLevel(of buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let rms = Self.meanSquareRoot(of: buffer) else {
            reportMeteringBlind(buffer)
            return
        }
        levelAccumulator += rms
        levelSampleCount += 1
        // Compressive curve: quiet speech lands mid-range instead of hugging the
        // floor, loud speech saturates gracefully — the bars feel ALIVE.
        let averageRMS = levelAccumulator / Float(levelSampleCount)
        let level = AudioLevelCurve.level(fromRMS: averageRMS)
        levelAccumulator = 0
        levelSampleCount = 0
        stateLock.lock()
        peakLevel = max(peakLevel, level)
        meteringDidRun = true
        stateLock.unlock()
        onLevel?(level)
    }

    /// RMS of channel 0, whatever the sample format. Returns nil only when the
    /// buffer exposes neither Float32 nor Int16 channel data.
    static func meanSquareRoot(of buffer: AVAudioPCMBuffer) -> Float? {
        let count = vDSP_Length(buffer.frameLength)
        var rms: Float = 0
        if let floats = buffer.floatChannelData?[0] {
            vDSP_rmsqv(floats, 1, &rms, count)
            return rms
        }
        if let ints = buffer.int16ChannelData?[0] {
            var scratch = [Float](repeating: 0, count: Int(buffer.frameLength))
            vDSP_vflt16(ints, 1, &scratch, 1, count)
            var scale = Float(1.0 / 32_768.0)
            vDSP_vsmul(scratch, 1, &scale, &scratch, 1, count)
            vDSP_rmsqv(scratch, 1, &rms, count)
            return rms
        }
        return nil
    }

    private func reportMeteringBlind(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let shouldLog = !meteringBlindReported
        meteringBlindReported = true
        stateLock.unlock()
        guard shouldLog else { return }
        Log.audio.error("level metering blind: unreadable buffer format \(buffer.format, privacy: .public) — falling back to the written-peak measurement")
    }

    /// The peak that cannot be blinded: `out` is always `targetFormat`.
    private func recordWrittenPeak(_ out: AVAudioPCMBuffer) {
        guard out.frameLength > 0, let rms = Self.meanSquareRoot(of: out) else { return }
        let level = AudioLevelCurve.level(fromRMS: rms)
        stateLock.lock()
        writtenPeakLevel = max(writtenPeakLevel, level)
        writtenPeakDidRun = true
        stateLock.unlock()
    }

    /// Phase 0: the number that actually matters for capture latency, and the one
    /// any voice-processing watchdog must be calibrated against.
    private func logFirstBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let shouldLog = !firstBufferLogged
        firstBufferLogged = true
        stateLock.unlock()
        guard shouldLog, let startedClock else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - startedClock.uptimeNanoseconds) / 1_000_000
        let format = buffer.format
        Log.audio.info("first buffer: \(ms, format: .fixed(precision: 1))ms after start on \(AudioInputDevices.currentDefaultName() ?? "unknown", privacy: .public) [\(AudioDeviceQuery.transportDescription(), privacy: .public)] — tap \(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat.rawValue)\(format.isInterleaved ? "/interleaved" : ""), \(buffer.frameLength) frames")
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

    /// How the default input is attached — built-in, Bluetooth, USB, aggregate.
    /// Logged because it is the single biggest predictor of capture-start latency
    /// (a Bluetooth HFP renegotiation is an order of magnitude slower than the
    /// built-in mic), so any deadline built on first-buffer timing must be a
    /// function of this, never a constant.
    static func transportDescription() -> String {
        guard let device = defaultInputDevice() else { return "no-device" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return "unknown"
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return "display"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        default: return "other"
        }
    }

    // NOTE: device *pinning* (kAudioOutputUnitProperty_CurrentDevice or
    // AUAudioUnit.setDeviceID on the input node) was probed on macOS 26 and leaves
    // the engine running with a silent tap — do not reintroduce it on AVAudioEngine.
}
