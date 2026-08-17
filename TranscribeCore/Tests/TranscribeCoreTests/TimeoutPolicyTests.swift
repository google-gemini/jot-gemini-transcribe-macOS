import XCTest
@testable import TranscribeCore

final class TimeoutPolicyTests: XCTestCase {
    func testOverallDeadlineScalesGently() {
        XCTAssertEqual(TimeoutPolicy.overallDeadline(audioDuration: 5), 31.25, accuracy: 0.01)
        XCTAssertEqual(TimeoutPolicy.overallDeadline(audioDuration: 30), 37.5, accuracy: 0.01)
        // 10-minute cap case: ~2.5 minutes, never the old 2×duration (20 min) formula.
        XCTAssertEqual(TimeoutPolicy.overallDeadline(audioDuration: 600), 180, accuracy: 0.01)
    }

    func testSlowStateFiresWellBeforeFirstByteDeadline() {
        XCTAssertLessThan(TimeoutPolicy.slowStateUI, TimeoutPolicy.timeToFirstByte)
    }
}
