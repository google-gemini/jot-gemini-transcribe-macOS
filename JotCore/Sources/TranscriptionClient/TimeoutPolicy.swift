import Foundation

/// The single source of truth for every network deadline in the app.
/// (Critic reconciliation #9 — no other file may define timeout constants.)
public enum TimeoutPolicy {
    /// TCP+TLS connect budget before the attempt is abandoned.
    public static let connect: TimeInterval = 5
    /// Time to the first SSE byte after the request body is sent.
    public static let timeToFirstByte: TimeInterval = 10
    /// Max gap between SSE chunks once streaming has begun.
    public static let interChunkStall: TimeInterval = 10
    /// When the HUD flips to the "Still working…" slow state.
    public static let slowStateUI: TimeInterval = 3

    /// Overall per-request deadline. Scales gently with audio length:
    /// 5s clip → 31s; 10min clip → 2.5min. Never the unbounded 2×duration formula.
    public static func overallDeadline(audioDuration: TimeInterval) -> TimeInterval {
        30 + audioDuration / 4
    }
}
