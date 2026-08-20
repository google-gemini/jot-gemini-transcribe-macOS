import Foundation

/// The one definition of Jot's 0…1 mic level, and its inverse.
///
/// `level = min(1, pow(min(rms * 11, 1), 0.65))` — a compressive curve so quiet
/// speech lands mid-range instead of hugging the floor and loud speech saturates
/// gracefully. It lives here, alone and tested, because every "did they speak?"
/// decision in the pipeline is arithmetic on its output: `silencePeakThreshold`
/// discards whole recordings, `trailingSpeechThreshold` decides whether the last
/// word is captured. A wrong constant here loses words silently.
///
/// The curve SATURATES at `rms = 1/gain` (≈ −20.8 dBFS): every level of 1.0 maps
/// back to that same RMS. Any SNR computed from these numbers is therefore a
/// **lower bound** — which is the safe direction, because it biases us toward
/// "this room is noisy", which biases us toward keeping audio.
public enum AudioLevelCurve {
    public static let gain: Float = 11
    public static let exponent: Float = 0.65

    /// The bottom of the scale — quieter than any real microphone, used so a
    /// digital-silence buffer has a finite dB value instead of −∞.
    public static let floorDBFS: Double = -120

    /// RMS (0…1 linear) → Jot level (0…1).
    public static func level(fromRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, pow(min(rms * gain, 1), exponent))
    }

    /// Jot level → RMS. Exact inverse below saturation; at level 1.0 it returns
    /// the saturation RMS, which is a floor on the true value, not the value.
    public static func rms(fromLevel level: Float) -> Float {
        guard level > 0 else { return 0 }
        return pow(min(level, 1), 1 / exponent) / gain
    }

    /// Jot level → dBFS. This is the space the noise-floor estimator works in:
    /// dB is where "6 dB above the room" is a meaningful sentence and
    /// "0.02 above the room" is not.
    public static func dBFS(fromLevel level: Float) -> Double {
        let linear = rms(fromLevel: level)
        guard linear > 0 else { return floorDBFS }
        return max(floorDBFS, 20 * log10(Double(linear)))
    }

    /// Where the curve stops distinguishing louder from loudest (≈ −20.8 dBFS).
    public static var saturationDBFS: Double { 20 * log10(1 / Double(gain)) }
}
