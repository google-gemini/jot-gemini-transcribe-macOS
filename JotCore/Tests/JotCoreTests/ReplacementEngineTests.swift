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

final class ReplacementEngineTests: XCTestCase {
    private func rule(_ wrong: String, _ right: String) -> ReplacementEngine.Rule {
        .init(wrong: wrong, right: right)
    }

    func testBasicReplacement() {
        let out = ReplacementEngine.apply([rule("cooper netties", "Kubernetes")], to: "deploy the cooper netties cluster")
        XCTAssertEqual(out, "deploy the Kubernetes cluster")
    }

    func testWordBoundaryRespected() {
        let out = ReplacementEngine.apply([rule("cat", "dog")], to: "the category has a cat")
        XCTAssertEqual(out, "the category has a dog")
    }

    func testLongestMatchWins() {
        let out = ReplacementEngine.apply(
            [rule("gemini", "Gemini"), rule("gemini api", "Gemini API")],
            to: "open gemini api now"
        )
        XCTAssertEqual(out, "open Gemini API now")
    }

    func testExplicitCasingCarries() {
        let out = ReplacementEngine.apply([rule("g r p c", "gRPC")], to: "The G R P C endpoint")
        XCTAssertEqual(out, "The gRPC endpoint")
    }

    func testCaseInsensitiveMatching() {
        let out = ReplacementEngine.apply([rule("genny", "Gemini")], to: "Genny is fast. genny wins.")
        XCTAssertEqual(out, "Gemini is fast. Gemini wins.")
    }

    func testLowercaseRulePropagatesSentenceCase() {
        let out = ReplacementEngine.apply([rule("standup", "stand-up")], to: "Standup at nine. The standup ran long.")
        XCTAssertEqual(out, "Stand-up at nine. The stand-up ran long.")
    }

    func testNoRulesIsIdentity() {
        XCTAssertEqual(ReplacementEngine.apply([], to: "unchanged"), "unchanged")
    }

    func testMultipleOccurrences() {
        let out = ReplacementEngine.apply([rule("amar", "Ammaar")], to: "amar told amar's team")
        XCTAssertEqual(out, "Ammaar told Ammaar's team")
    }
}
