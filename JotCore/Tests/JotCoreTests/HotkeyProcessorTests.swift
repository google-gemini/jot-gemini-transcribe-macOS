import XCTest
@testable import JotCore

final class HotkeyProcessorTests: XCTestCase {
    private var processor = HotkeyProcessor()

    override func setUp() {
        super.setUp()
        processor = HotkeyProcessor()
    }

    @discardableResult
    private func send(_ event: HotkeyProcessor.Event, at t: TimeInterval) -> HotkeyProcessor.Effects {
        processor.handle(event, at: t)
    }

    // MARK: Hold (push-to-talk)

    func testHoldSpeakRelease() {
        XCTAssertEqual(send(.hotkeyDown, at: 0).intents, [.begin])
        let fx = send(.hotkeyUp, at: 2.5)
        XCTAssertEqual(fx.intents, [.finalize])
        XCTAssertFalse(processor.isSessionActive)
    }

    func testHoldExactlyAtThresholdIsHold() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.hotkeyUp, at: HotkeyTuning.holdThreshold).intents, [.finalize])
    }

    // MARK: Space-while-holding → hands-free lock (timing-free, the default gesture)

    func testSpaceWhileHoldingLocks() {
        XCTAssertEqual(send(.hotkeyDown, at: 0).intents, [.begin])
        XCTAssertEqual(send(.spaceLock, at: 0.8).intents, [.lockIn])
        XCTAssertEqual(send(.hotkeyUp, at: 1.2).intents, [], "fn release after Space-lock must not finalize")
        XCTAssertTrue(processor.isSessionActive)
        XCTAssertEqual(send(.hotkeyDown, at: 5).intents, [.finalize], "press again stops")
    }

    func testSpaceLockWorksEvenAfterLongHold() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.spaceLock, at: 4.0).intents, [.lockIn], "no timing window — any time while held")
    }

    func testSpaceInIdleAndLockedDoesNothing() {
        XCTAssertEqual(send(.spaceLock, at: 0).intents, [], "idle: space is just typing")
        send(.hotkeyDown, at: 1)
        send(.spaceLock, at: 1.5)
        XCTAssertEqual(send(.spaceLock, at: 2).intents, [], "already locked: inert")
    }

    func testEscCancelsAfterSpaceLock() {
        send(.hotkeyDown, at: 0)
        send(.spaceLock, at: 0.5)
        XCTAssertEqual(send(.escDown, at: 2).intents, [.cancel])
    }

    // MARK: Single short tap → coaching hint

    func testShortTapArmsTimerThenHints() {
        processor.doubleTapLockEnabled = true
        XCTAssertEqual(send(.hotkeyDown, at: 0).intents, [.begin])
        let up = send(.hotkeyUp, at: 0.1)
        XCTAssertEqual(up.intents, [])
        XCTAssertEqual(up.armTimer, HotkeyTuning.doubleTapWindow)
        XCTAssertTrue(processor.isSessionActive, "still recording during the double-tap window")
        XCTAssertEqual(send(.doubleTapTimeout, at: 0.7).intents, [.shortTapHint])
        XCTAssertFalse(processor.isSessionActive)
    }

    func testShortTapHintsImmediatelyByDefault() {
        // Double-tap is opt-in now (dogfood: firm taps misread as holds).
        send(.hotkeyDown, at: 0)
        let up = send(.hotkeyUp, at: 0.1)
        XCTAssertEqual(up.intents, [.shortTapHint])
        XCTAssertNil(up.armTimer)
    }

    // MARK: Double-tap → hands-free lock (opt-in)

    func testDoubleTapLocksThenPressStops() {
        processor.doubleTapLockEnabled = true
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        let lock = send(.hotkeyDown, at: 0.3)
        XCTAssertEqual(lock.intents, [.lockIn])
        XCTAssertTrue(lock.disarmTimer)
        XCTAssertEqual(send(.hotkeyUp, at: 0.4).intents, [], "second tap's release is swallowed")
        XCTAssertTrue(processor.isSessionActive)
        // Press again = stop.
        XCTAssertEqual(send(.hotkeyDown, at: 5.0).intents, [.finalize])
        XCTAssertEqual(send(.hotkeyUp, at: 5.1).intents, [], "stop press release swallowed")
        XCTAssertFalse(processor.isSessionActive)
    }

    func testLockedIgnoresTypingAndTimeout() {
        processor.doubleTapLockEnabled = true
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        send(.hotkeyDown, at: 0.3)
        send(.hotkeyUp, at: 0.4)
        XCTAssertEqual(send(.otherKeyDown, at: 2).intents, [], "typing while locked is allowed")
        XCTAssertEqual(send(.doubleTapTimeout, at: 3).intents, [], "stale timer ignored")
        XCTAssertTrue(processor.isSessionActive)
    }

    // MARK: Esc cancels

    func testEscWhileHolding() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.escDown, at: 1).intents, [.cancel])
        XCTAssertEqual(send(.hotkeyUp, at: 1.2).intents, [], "release after cancel is inert")
        XCTAssertFalse(processor.isSessionActive)
    }

    func testEscDuringDoubleTapWindow() {
        processor.doubleTapLockEnabled = true
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        let fx = send(.escDown, at: 0.2)
        XCTAssertEqual(fx.intents, [.cancel])
        XCTAssertTrue(fx.disarmTimer)
    }

    func testEscWhileLocked() {
        processor.doubleTapLockEnabled = true
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        send(.hotkeyDown, at: 0.3)
        send(.hotkeyUp, at: 0.4)
        XCTAssertEqual(send(.escDown, at: 2).intents, [.cancel])
    }

    // MARK: Accidental chord guard

    func testTypingDuringEarlyHoldAborts() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.otherKeyDown, at: 0.5).intents, [.abortAccidental])
        XCTAssertEqual(send(.hotkeyUp, at: 0.6).intents, [], "release after abort is inert")
    }

    func testTypingAfterInterruptionWindowKeepsRecording() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.otherKeyDown, at: 1.5).intents, [], "deliberate chording after 1s is fine")
        XCTAssertTrue(processor.isSessionActive)
        XCTAssertEqual(send(.hotkeyUp, at: 3).intents, [.finalize])
    }

    func testTypingDuringDoubleTapWindow() {
        processor.doubleTapLockEnabled = true
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        let fx = send(.otherKeyDown, at: 0.2)
        XCTAssertEqual(fx.intents, [.abortAccidental], "within the 1s interruption window")
        XCTAssertTrue(fx.disarmTimer)
    }

    // MARK: Sequences & robustness

    func testNewSessionAfterHint() {
        processor.doubleTapLockEnabled = true
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        send(.doubleTapTimeout, at: 0.6)
        XCTAssertEqual(send(.hotkeyDown, at: 1.0).intents, [.begin], "fresh session after hint")
    }

    func testSlowSecondTapStartsNewSession() {
        processor.doubleTapLockEnabled = true
        send(.hotkeyDown, at: 0)
        send(.hotkeyUp, at: 0.1)
        send(.doubleTapTimeout, at: 0.61) // window expired → hint
        let fx = send(.hotkeyDown, at: 0.8) // too late to lock
        XCTAssertEqual(fx.intents, [.begin])
    }

    func testStrayEventsInIdleAreInert() {
        XCTAssertEqual(send(.hotkeyUp, at: 0).intents, [])
        XCTAssertEqual(send(.escDown, at: 1).intents, [])
        XCTAssertEqual(send(.otherKeyDown, at: 2).intents, [])
        XCTAssertEqual(send(.doubleTapTimeout, at: 3).intents, [])
        XCTAssertFalse(processor.isSessionActive)
    }

    func testDoubleTapDisabledHintsImmediately() {
        processor.doubleTapLockEnabled = false
        send(.hotkeyDown, at: 0)
        let up = send(.hotkeyUp, at: 0.1)
        XCTAssertEqual(up.intents, [.shortTapHint], "no pending window when lock is disabled")
        XCTAssertNil(up.armTimer)
        XCTAssertFalse(processor.isSessionActive)
    }

    func testRepeatedDownWhilePressedIsIgnored() {
        send(.hotkeyDown, at: 0)
        XCTAssertEqual(send(.hotkeyDown, at: 0.1).intents, [], "duplicate down (flag glitch) ignored")
        XCTAssertEqual(send(.hotkeyUp, at: 1).intents, [.finalize])
    }
}
