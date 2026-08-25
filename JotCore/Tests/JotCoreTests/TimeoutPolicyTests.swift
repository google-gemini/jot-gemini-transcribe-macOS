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
