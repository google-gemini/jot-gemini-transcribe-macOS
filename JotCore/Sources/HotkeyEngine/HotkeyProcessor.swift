import Foundation

/// The pure hotkey grammar (Wispr style — critic reconciliation #1):
///
///   hold ≥ 0.3s            → push-to-talk: key-up finalizes
///   tap, tap (≤ 0.35s gap) → hands-free lock: press again finalizes
///   single tap             → coaching hint, session quietly cancelled
///   Esc                    → cancel
///   other key < 1s in      → accidental chord, silent abort
///
/// Recording ALWAYS starts on the first key-down (`.begin`) so no audio is ever
/// lost while the grammar disambiguates. Between the taps of a double-tap the
/// session keeps recording.
///
/// Pure and clock-free: callers pass monotonic timestamps; timers are returned as
/// effects and fed back in as `.doubleTapTimeout`. Exhaustively unit-tested.
public struct HotkeyProcessor {
    public enum Event: Equatable, Sendable {
        case hotkeyDown
        case hotkeyUp
        case escDown
        case otherKeyDown
        /// Space pressed while the hotkey is physically held — the timing-free
        /// hands-free gesture ("hold, tap Space, let go").
        case spaceLock
        /// The double-tap window expired (fed back by the timer the caller armed).
        case doubleTapTimeout
    }

    public struct Effects: Equatable, Sendable {
        public var intents: [HotkeyIntent] = []
        /// Arm the double-tap timer to fire after this many seconds (nil = leave as-is).
        public var armTimer: TimeInterval?
        public var disarmTimer = false
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Key physically down, classification pending (hold vs tap).
        case pressed(downAt: TimeInterval, sessionStartAt: TimeInterval)
        /// First short tap released; waiting for a possible second tap. Still recording.
        case pendingSecondTap(sessionStartAt: TimeInterval)
        /// Hands-free.
        case locked
    }

    public private(set) var phase: Phase = .idle

    /// Snap back to idle after the coordinator REFUSES a begin (secure field,
    /// busy) — otherwise a Space-lock on the phantom session strands the grammar
    /// in .locked and silently eats the next dictation attempt.
    public mutating func reset() {
        phase = .idle
        swallowNextUp = false
    }
    /// When off, a short tap hints immediately and never arms the double-tap
    /// window — for users who find tap-tap colliding with quick holds.
    /// Default OFF since dogfood: firm taps routinely exceed the hold threshold,
    /// misreading tap-tap as hold→finalize. Space-while-holding replaced it.
    public var doubleTapLockEnabled = false
    /// True while the hotkey is physically down (the Space-lock gesture window).
    public var isKeyHeld: Bool {
        if case .pressed = phase { return true }
        return false
    }
    /// True whenever a dictation session is in flight from the hotkey's perspective —
    /// the event tap uses this to decide whether to intercept Esc.
    public var isSessionActive: Bool { phase != .idle }
    /// When set, the next key-up of the hotkey belongs to an already-classified press
    /// (lock stop, cancel, abort) and must be swallowed without effects.
    private var swallowNextUp = false

    public init() {}

    public mutating func handle(_ event: Event, at now: TimeInterval) -> Effects {
        var fx = Effects()
        switch (phase, event) {

        // MARK: idle
        case (.idle, .hotkeyDown):
            phase = .pressed(downAt: now, sessionStartAt: now)
            swallowNextUp = false
            fx.intents = [.begin]

        case (.idle, .hotkeyUp):
            // Residual up from a press we already classified (lock stop, cancel…).
            swallowNextUp = false

        case (.idle, _):
            break

        // MARK: pressed (key down, disambiguating)
        case (.pressed(let downAt, let startAt), .hotkeyUp):
            if swallowNextUp {
                swallowNextUp = false
                break
            }
            if now - downAt >= HotkeyTuning.holdThreshold {
                phase = .idle
                fx.intents = [.finalize]
            } else if doubleTapLockEnabled {
                phase = .pendingSecondTap(sessionStartAt: startAt)
                fx.armTimer = HotkeyTuning.doubleTapWindow
            } else {
                phase = .idle
                fx.intents = [.shortTapHint]
            }

        case (.pressed, .escDown):
            phase = .idle
            swallowNextUp = true
            fx.intents = [.cancel]

        case (.pressed(_, let startAt), .otherKeyDown):
            if now - startAt < HotkeyTuning.interruptionWindow {
                phase = .idle
                swallowNextUp = true
                fx.intents = [.abortAccidental]
            }
            // After the window: user is deliberately chording/typing mid-hold — keep going.

        case (.pressed, .spaceLock):
            // Hold + tap Space = hands-free, no timing window. The fn release that
            // follows belongs to this gesture and must not finalize.
            phase = .locked
            swallowNextUp = true
            fx.intents = [.lockIn]

        case (.pressed, .hotkeyDown), (.pressed, .doubleTapTimeout):
            break

        // MARK: pendingSecondTap (short tap released, window open, still recording)
        case (.pendingSecondTap, .hotkeyDown):
            phase = .locked
            swallowNextUp = true
            fx.intents = [.lockIn]
            fx.disarmTimer = true

        case (.pendingSecondTap, .doubleTapTimeout):
            phase = .idle
            fx.intents = [.shortTapHint]

        case (.pendingSecondTap, .escDown):
            phase = .idle
            fx.intents = [.cancel]
            fx.disarmTimer = true

        case (.pendingSecondTap(let startAt), .otherKeyDown):
            phase = .idle
            fx.disarmTimer = true
            fx.intents = [now - startAt < HotkeyTuning.interruptionWindow ? .abortAccidental : .cancel]

        case (.pendingSecondTap, .hotkeyUp):
            swallowNextUp = false

        case (.pendingSecondTap, .spaceLock):
            break // key not held — Space types normally

        // MARK: locked (hands-free)
        case (.locked, .hotkeyDown):
            phase = .idle
            swallowNextUp = true
            fx.intents = [.finalize]

        case (.locked, .escDown):
            phase = .idle
            fx.intents = [.cancel]

        case (.locked, .hotkeyUp):
            swallowNextUp = false

        case (.locked, .otherKeyDown), (.locked, .doubleTapTimeout), (.locked, .spaceLock):
            break
        }
        return fx
    }
}
