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

/// The diff behind the HUD's "here is what got removed" animation. It runs on
/// every live dictation and its output is shown to the user, so it has to be
/// right about ordinary speech and, more importantly, has to fail quietly on
/// speech it cannot align.
final class TranscriptDiffTests: XCTestCase {

    private func cutText(_ segments: [TranscriptDiff.Segment]) -> String {
        segments.filter(\.isCut).map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }
    private func keptText(_ segments: [TranscriptDiff.Segment]) -> String {
        segments.filter { !$0.isCut }.map(\.text).joined()
    }

    /// Joining every segment must reproduce the original exactly, or the HUD
    /// would render a sentence the user never said.
    private func assertLossless(_ segments: [TranscriptDiff.Segment], _ original: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(segments.map(\.text).joined(), original,
                       "segments must reassemble the original verbatim text", file: file, line: line)
    }

    /// The landing page's own example.
    func testFillersAndSelfCorrectionAreCut() {
        let said = "umm, so let's meet at 1pm — actually, no, make it 2pm"
        let clean = "Let's meet at 2pm."
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: clean)
        assertLossless(segments, said)

        let cut = cutText(segments)
        XCTAssertTrue(cut.contains("umm"), "filler must be marked, got cuts: \(cut)")
        XCTAssertTrue(cut.contains("actually"), "self-correction must be marked, got cuts: \(cut)")
        XCTAssertTrue(cut.contains("1pm"), "the replaced time must be marked, got cuts: \(cut)")
        XCTAssertTrue(keptText(segments).contains("2pm"), "the surviving time must be kept")
    }

    /// The user's own sentence from dogfooding.
    func testRealDictationKeepsTheSubstance() {
        let said = "hey um turn this call from 2pm to 3pm"
        let clean = "Hey, turn this call from 2pm to 3pm."
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: clean)
        assertLossless(segments, said)
        XCTAssertTrue(cutText(segments).contains("um"), "the filler should be the cut")
        let kept = keptText(segments)
        for word in ["turn", "call", "2pm", "3pm"] {
            XCTAssertTrue(kept.contains(word), "\(word) must survive")
        }
    }

    /// Punctuation and capitalisation are what smart mode ADDS. Comparing raw
    /// text would mark every word as removed and paint the whole sentence red.
    func testPunctuationAndCasingAreNotTreatedAsEdits() {
        let said = "lets meet at 2pm"
        let clean = "Let's meet at 2pm."
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: clean)
        assertLossless(segments, said)
        XCTAssertEqual(cutText(segments), "", "casing and punctuation must not read as removals")
    }

    func testNothingRemovedYieldsOneKeptSegment() {
        let said = "turn the call to 3pm"
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: "Turn the call to 3pm.")
        XCTAssertEqual(segments.filter(\.isCut).count, 0)
        assertLossless(segments, said)
    }

    /// If the model rewrote wholesale rather than trimmed, there is no honest
    /// edit to show. Marking the entire sentence as deleted would be a bug
    /// rendered at full size, so it must fail to "no edit".
    func testUnrelatedTextsShowNoEdit() {
        let said = "the quick brown fox"
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: "completely different words here")
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].isCut, "an unalignable pair must render as unedited, never all-red")
        assertLossless(segments, said)
    }

    /// Order matters: a repeated word must be matched in sequence, not by mere
    /// membership, or the first "1pm" would survive because a later one exists.
    func testRepeatedWordsMatchInOrder() {
        let said = "meet at 1pm no meet at 2pm"
        let clean = "Meet at 2pm."
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: clean)
        assertLossless(segments, said)
        XCTAssertTrue(cutText(segments).contains("1pm"), "the abandoned time must be cut, got: \(cutText(segments))")
    }

    func testEmptyInputsAreSafe() {
        XCTAssertEqual(TranscriptDiff.segments(verbatim: "", cleaned: "anything"), [])
        let segments = TranscriptDiff.segments(verbatim: "some words", cleaned: "")
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].isCut)
    }

    /// Adjacent words of the same kind coalesce, so the UI animates a few runs
    /// rather than one span per word.
    func testAdjacentTokensCoalesce() {
        let said = "umm uh so let's go"
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: "Let's go.")
        assertLossless(segments, said)
        XCTAssertLessThanOrEqual(segments.count, 2, "three consecutive fillers should be one run, got \(segments)")
    }

    /// Whitespace must survive intact — the collapse animation removes the run
    /// including its trailing space, and a lost space would jam words together.
    func testWhitespaceIsPreserved() {
        let said = "hello   world  again"
        let segments = TranscriptDiff.segments(verbatim: said, cleaned: "Hello world again.")
        assertLossless(segments, said)
    }
}
