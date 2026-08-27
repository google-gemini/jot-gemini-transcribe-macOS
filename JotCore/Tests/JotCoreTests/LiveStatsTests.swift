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

import XCTest
@testable import JotCore

/// The counters that make live mode's reliability answerable, and the guard that
/// stops a broken live path taxing every dictation.
final class LiveStatsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var stats: LiveStats!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "live-stats-tests-\(UUID().uuidString)")
        stats = LiveStats(defaults: defaults)
    }

    func testSuccessAndFallbackBothCountAsAttempts() {
        stats.recordSuccess()
        stats.recordFallback(.noFinal)
        stats.recordSuccess()
        XCTAssertEqual(stats.attempts, 3)
        XCTAssertEqual(stats.successes, 2)
        XCTAssertEqual(stats.count(of: .noFinal), 1)
    }

    /// The guard: three failures in a row stops it, because by then every
    /// dictation is paying for a handshake and then uploading anyway.
    func testStopsTryingAfterThreeConsecutiveFailures() {
        XCTAssertFalse(stats.shouldStopTrying)
        stats.recordFallback(.neverOpened)
        stats.recordFallback(.neverOpened)
        XCTAssertFalse(stats.shouldStopTrying, "two is a bad moment, not a broken feature")
        stats.recordFallback(.neverOpened)
        XCTAssertTrue(stats.shouldStopTrying)
    }

    /// A flaky network must heal itself — one good dictation is enough.
    func testOneSuccessClearsTheStreak() {
        for _ in 0..<5 { stats.recordFallback(.droppedMidSession) }
        XCTAssertTrue(stats.shouldStopTrying)
        stats.recordSuccess()
        XCTAssertFalse(stats.shouldStopTrying, "live must recover without the user touching a setting")
        XCTAssertEqual(stats.consecutiveFailures, 0)
    }

    /// Re-enabling the toggle is an explicit "try again", but must not erase the
    /// evidence — the footer should still tell the truth afterwards.
    func testClearStreakKeepsHistory() {
        for _ in 0..<4 { stats.recordFallback(.truncated) }
        stats.clearStreak()
        XCTAssertFalse(stats.shouldStopTrying)
        XCTAssertEqual(stats.attempts, 4, "history survives")
        XCTAssertEqual(stats.count(of: .truncated), 4)
    }

    func testNoSummaryBeforeAnyAttempts() {
        XCTAssertNil(stats.summary, "an empty stat line is worse than none")
    }

    func testSummaryReportsRateAndDominantReason() throws {
        for _ in 0..<7 { stats.recordSuccess() }
        for _ in 0..<3 { stats.recordFallback(.droppedMidSession) }
        let summary = try XCTUnwrap(stats.summary)
        XCTAssertTrue(summary.contains("7 of the last 10"), summary)
        XCTAssertTrue(summary.contains("70%"), summary)
        XCTAssertTrue(summary.contains("dropped mid-sentence"),
                      "the dominant reason is what tells the user whether to blame wifi or us: \(summary)")
    }

    func testPerfectRunMentionsNoFailure() throws {
        for _ in 0..<4 { stats.recordSuccess() }
        let summary = try XCTUnwrap(stats.summary)
        XCTAssertFalse(summary.contains("fell back"), summary)
    }

    /// The session's own free-text reasons must land in the right bucket, or the
    /// footer will confidently blame the wrong thing.
    func testClassificationOfRealSessionReasons() {
        XCTAssertEqual(LiveStats.classify("dropped 3 chunks — stream is truncated"), .truncated)
        XCTAssertEqual(LiveStats.classify("setup never completed"), .neverOpened)
        XCTAssertEqual(LiveStats.classify("connect failed: offline"), .neverOpened)
        XCTAssertEqual(LiveStats.classify("no final transcript before deadline"), .noFinal)
        XCTAssertEqual(LiveStats.classify("final transcript was empty"), .noFinal)
        XCTAssertEqual(LiveStats.classify("server sent goAway"), .droppedMidSession)
        XCTAssertEqual(LiveStats.classify("something nobody anticipated"), .droppedMidSession,
                       "an unknown reason must still be counted, not dropped")
    }

    func testResetClearsEverything() {
        stats.recordSuccess()
        stats.recordFallback(.noFinal)
        stats.reset()
        XCTAssertEqual(stats.attempts, 0)
        XCTAssertEqual(stats.successes, 0)
        XCTAssertEqual(stats.count(of: .noFinal), 0)
        XCTAssertNil(stats.summary)
    }
}
