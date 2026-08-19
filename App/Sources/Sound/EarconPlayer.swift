import AVFoundation
import JotCore

/// Preloaded earcon playback (<10ms trigger latency). Sounds fire on the same
/// state-machine tick as the matching animation — the Pixel frame-sync principle.
/// No sounds on hover/menus, ever: design the silence.
@MainActor
final class EarconPlayer {
    enum Earcon: String, CaseIterable {
        case start, stop, lock, success, cancel, error, celebration
    }

    private var players: [Earcon: AVAudioPlayer] = [:]
    /// Live-follows the Settings toggle (UserDefaults reads are cheap).
    var enabled: Bool { SettingsStore().soundsEnabled }

    init() {
        // Loading 7 players blocks the caller (~120ms measured) — never on the
        // main thread at launch, and never in front of the first key press.
        loadInBackground()
    }

    private func loadInBackground() {
        Task.detached(priority: .utility) { [weak self] in
            let loaded = EarconPlayer.loadPlayers()
            guard let self else { return }
            await self.adopt(loaded) // @MainActor — hops back on its own
        }
    }

    private func adopt(_ loaded: [Earcon: AVAudioPlayer]) {
        players = loaded
        warmOutputRoute()
    }

    nonisolated private static func loadPlayers() -> [Earcon: AVAudioPlayer] {
        var players: [Earcon: AVAudioPlayer] = [:]
        for earcon in Earcon.allCases {
            guard let url = Bundle.main.url(forResource: earcon.rawValue, withExtension: "wav", subdirectory: "Sounds") else {
                Log.ui.warning("EarconPlayer: missing \(earcon.rawValue, privacy: .public).wav")
                continue
            }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                player.volume = 0.9
                players[earcon] = player
            }
        }
        return players
    }

    /// The FIRST play() of a player instance blocks its caller while the
    /// AudioQueue is built and the output route spins up — measured 45–475ms on
    /// a USB/Bluetooth output. That otherwise lands on the start earcon, ahead of
    /// the mic, so the first dictation after launch loses that much leading
    /// speech. Pay it once, silently, off the main actor. Never stop() a player:
    /// an explicit stop re-costs the next play ~440ms.
    private func warmOutputRoute() {
        guard let player = players[.start] else { return }
        nonisolated(unsafe) let warm = player
        let volume = warm.volume
        warm.volume = 0
        Task.detached(priority: .utility) {
            warm.play()
            try? await Task.sleep(nanoseconds: UInt64((warm.duration + 0.05) * 1_000_000_000))
            await MainActor.run { warm.volume = volume }
        }
    }

    func play(_ earcon: Earcon) {
        guard enabled, let player = players[earcon] else { return }
        player.currentTime = 0
        player.play()
    }
}
