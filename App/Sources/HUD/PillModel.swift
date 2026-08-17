import SwiftUI

/// The pill's semantic state — a pure projection of coordinator state
/// (experience spec owns all timing/lifecycle; critic reconciliation #7).
enum PillState: Equatable {
    case hidden
    case idleDot
    case listening(locked: Bool)
    case processing
    case success(words: Int?)
    /// Neutral informational chip (coaching hint, copied-to-clipboard, offline…).
    case notice(String)
    /// Error styling: errorContainer surface + "saved to History" framing.
    case error(String)
}

@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .idleDot
    @Published var level: Float = 0
    @Published var elapsed: TimeInterval = 0
    /// Still-working slow state (>3s in processing — TimeoutPolicy.slowStateUI).
    @Published var slow = false
}
