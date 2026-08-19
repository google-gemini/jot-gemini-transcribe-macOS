import AVFoundation
import Foundation
import JotCore

/// Keeps one capture graph built and prepared while the app is idle, so a key
/// press pays only `engine.start()`.
///
/// Measured on this machine (Bluetooth route): building the graph costs 75–135ms
/// — `engine.inputNode` alone is 42–68ms of HAL work — and that window is exactly
/// where a user's first words are lost. Preparing is not recording: no audio
/// flows and no microphone indicator appears until start().
///
/// Concurrency: a spare is built on a utility queue and only published once fully
/// prepared, so nothing ever touches a graph that is still being built.
@MainActor
final class WarmEnginePool {
    private var spare: AudioCaptureEngine?
    private var buildingSpare = false

    /// The engine for a session that is starting right now. Immediately begins
    /// building the next spare so back-to-back dictations stay warm.
    func take() -> AudioCaptureEngine {
        defer { prewarmNext() }
        if let spare {
            self.spare = nil
            return spare
        }
        // Cold path (first launch, mic just authorized, device changed): correct,
        // just slower — the session builds its own graph.
        return AudioCaptureEngine()
    }

    func prewarmNext() {
        guard spare == nil, !buildingSpare else { return }
        // Never touch the mic stack before the user has granted access: doing so
        // would trigger the permission prompt out of nowhere.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        buildingSpare = true
        Task.detached(priority: .utility) {
            let engine = AudioCaptureEngine()
            engine.prewarm()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.buildingSpare = false
                self.spare = engine
            }
        }
    }

    /// Drop the spare (e.g. the input device changed under it) and build a fresh
    /// one for the new route.
    func refresh() {
        spare = nil
        prewarmNext()
    }
}
