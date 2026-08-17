import AVFoundation
import TranscribeCore

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
    }

    func play(_ earcon: Earcon) {
        guard enabled, let player = players[earcon] else { return }
        player.currentTime = 0
        player.play()
    }
}
