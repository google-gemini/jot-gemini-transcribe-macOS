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

final class SnippetExpansionTests: XCTestCase {
    private func snippet(_ trigger: String, _ expansion: String) -> ReplacementEngine.Snippet {
        .init(trigger: trigger, expansion: expansion)
    }

    func testExpandsSpokenTrigger() {
        let out = ReplacementEngine.expand(
            [snippet("my email address", "dev@example.com")],
            in: "Ping me at my email address when you land"
        )
        XCTAssertEqual(out, "Ping me at dev@example.com when you land")
    }

    /// The single most important difference from a spelling rule. `apply` does
    /// case propagation on purpose — "Standup"→"Stand-up" should follow the
    /// sentence. An expansion must NOT: a trigger at the start of a sentence
    /// would Title-Case an address or upper-case a phone number's words.
    func testExpansionIsVerbatimNeverCaseAdjusted() {
        let out = ReplacementEngine.expand(
            [snippet("my email address", "dev@example.com")],
            in: "My email address is the best way to reach me."
        )
        XCTAssertEqual(out, "dev@example.com is the best way to reach me.",
                       "sentence-start capitalisation must not leak into the expansion")
    }

    func testAllCapsTriggerStillExpandsVerbatim() {
        let out = ReplacementEngine.expand([snippet("my number", "(720) 555-0134")], in: "MY NUMBER")
        XCTAssertEqual(out, "(720) 555-0134")
    }

    func testLongestTriggerWins() {
        let out = ReplacementEngine.expand(
            [snippet("my email", "personal@example.com"), snippet("my work email", "work@example.com")],
            in: "use my work email please"
        )
        XCTAssertEqual(out, "use work@example.com please")
    }

    /// Expansion is deliberately NOT re-entrant. Matching runs against the
    /// original text and the gaps are copied, so a trigger that happens to appear
    /// inside another snippet's expansion stays literal — no surprise cascade and
    /// no way to build a recursive pair that never terminates.
    func testExpansionIsNotRescanned() {
        let out = ReplacementEngine.expand(
            [snippet("my signature", "Sudarshan — my number"), snippet("my number", "(720) 555-0134")],
            in: "my signature"
        )
        XCTAssertEqual(out, "Sudarshan — my number",
                       "a trigger inside an expansion must stay literal")
    }

    func testWordBoundaryRespected() {
        let out = ReplacementEngine.expand([snippet("sig", "SIGNATURE")], in: "the design is assigned")
        XCTAssertEqual(out, "the design is assigned")
    }

    /// The model punctuates, so the trigger almost always arrives with a period
    /// or comma attached. The lookarounds must let that through untouched.
    func testTrailingPunctuationSurvives() {
        let out = ReplacementEngine.expand([snippet("my number", "(720) 555-0134")], in: "Call my number, thanks.")
        XCTAssertEqual(out, "Call (720) 555-0134, thanks.")
    }

    func testMultipleOccurrences() {
        let out = ReplacementEngine.expand([snippet("my email", "dev@example.com")], in: "my email or my email")
        XCTAssertEqual(out, "dev@example.com or dev@example.com")
    }

    func testMultilineExpansionKeepsItsShape() {
        let out = ReplacementEngine.expand([snippet("my signoff", "Thanks,\nSudarshan")], in: "my signoff")
        XCTAssertEqual(out, "Thanks,\nSudarshan")
    }

    func testNoSnippetsIsIdentity() {
        XCTAssertEqual(ReplacementEngine.expand([], in: "unchanged"), "unchanged")
    }

    func testEmptyTriggerOrExpansionIsIgnored() {
        let out = ReplacementEngine.expand(
            [snippet("", "boom"), snippet("trigger", "")],
            in: "trigger stays"
        )
        XCTAssertEqual(out, "trigger stays")
    }
}

/// The ORDER guarantee between the dictionary's two post-model passes.
final class DictionaryPipelineOrderTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }

    /// Spelling rules run BEFORE expansion, so a rule can never rewrite the
    /// inside of freshly-inserted user text. Reversed, the "gmail"→"GMail" rule
    /// below would corrupt the address the user just expanded — their own email,
    /// silently edited into something they never wrote.
    func testSpellingRulesNeverRewriteInsideAnExpansion() {
        _ = store.add(term: "GMail", misspelling: "gmail")
        _ = store.add(term: "my email", expansion: "dev@gmail.com")

        let out = GeminiTranscriptionService.applyDictionary(to: "reach me at my email", store)
        XCTAssertEqual(out, "reach me at dev@gmail.com",
                       "the expansion is user data and must survive the spelling pass untouched")
    }

    /// Both halves still work when they don't collide.
    func testSpellingAndExpansionBothApply() {
        _ = store.add(term: "Kubernetes", misspelling: "cooper netties")
        _ = store.add(term: "my number", expansion: "(720) 555-0134")

        let out = GeminiTranscriptionService.applyDictionary(to: "cooper netties — call my number", store)
        XCTAssertEqual(out, "Kubernetes — call (720) 555-0134")
    }
}

final class DictionarySnippetStoreTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }

    /// The privacy line that matters: a dictionary full of addresses and phone
    /// numbers must add nothing to what the request carries. Triggers ride along
    /// (that is what makes the recogniser hear them); expansions never do.
    func testExpansionsNeverReachTheVocabulary() {
        _ = store.add(term: "my email address", expansion: "dev@example.com")
        let vocabulary = store.sanitizedVocabulary()
        XCTAssertTrue(vocabulary.contains("my email address"), "the spoken trigger is a term like any other")
        XCTAssertFalse(vocabulary.contains { $0.contains("dev@example.com") },
                       "an expansion must never leave the machine")
    }

    func testSnippetsSurviveACSVRoundTrip() {
        _ = store.add(term: "my signoff", expansion: "Thanks,\nSudarshan — \"the\" one, x")
        let csv = store.exportCSV()

        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
        XCTAssertEqual(store.importCSV(csv), 1)

        let restored = store.entries().first
        XCTAssertEqual(restored?.term, "my signoff")
        XCTAssertEqual(restored?.expansion, "Thanks,\nSudarshan — \"the\" one, x",
                       "commas, quotes and newlines are all legal inside an expansion")
    }

    /// A headerless file whose first term happens to start with "term" must not
    /// lose its first row — the existing guard, re-checked with three columns.
    func testThreeColumnHeaderIsDroppedButDataIsNot() {
        XCTAssertEqual(store.importCSV("term,misspelling,expansion\n\"terminal\",\"\",\"\""), 1)
        XCTAssertEqual(store.entries().first?.term, "terminal")
    }

    func testOverlongExpansionIsRefused() {
        let huge = String(repeating: "x", count: DictionaryEntry.maxExpansionLength + 1)
        XCTAssertFalse(store.add(term: "my essay", expansion: huge))
        XCTAssertTrue(store.entries().isEmpty)
    }

    /// An entry with no expansion is still a plain term, and must not turn up as
    /// a snippet with an empty replacement (which would delete the trigger).
    func testPlainTermsAreNotSnippets() {
        _ = store.add(term: "Kubernetes", misspelling: "cooper netties")
        XCTAssertTrue(store.snippets().isEmpty)
    }
}

/// The stored shape. `expansion` was added to a struct that is already on disk
/// in every existing install, so the old form has to keep decoding — a throw
/// here empties somebody's dictionary on upgrade.
final class DictionaryEntryWireFormatTests: XCTestCase {
    private func decode(_ json: String) throws -> [DictionaryEntry] {
        try JSONDecoder().decode([DictionaryEntry].self, from: Data(json.utf8))
    }

    func testDecodesEntriesWrittenBeforeExpansionExisted() throws {
        let legacy = """
        [{"id":"1B4E28BA-2FA1-11D2-883F-B9A761BDE3FB","term":"Kubernetes",\
        "misspelling":"cooper netties","starred":false,"createdAt":800000000.0}]
        """
        let entries = try decode(legacy)
        XCTAssertEqual(entries.first?.term, "Kubernetes")
        XCTAssertNil(entries.first?.expansion)
        XCTAssertFalse(entries.first?.isSnippet ?? true)
    }

    func testDecodesASnippetEntry() throws {
        let stored = """
        [{"id":"1B4E28BA-2FA1-11D2-883F-B9A761BDE3FB","term":"my email address",\
        "expansion":"dev@example.com","starred":true,"createdAt":800000000.0}]
        """
        let entry = try XCTUnwrap(decode(stored).first)
        XCTAssertEqual(entry.expansion, "dev@example.com")
        XCTAssertTrue(entry.isSnippet)
        XCTAssertNil(entry.misspelling)
    }

    /// Round-tripping through the encoder must produce something the decoder
    /// accepts — the guard against a future field being added non-optionally.
    func testRoundTripsThroughItsOwnEncoder() throws {
        let original = DictionaryEntry(term: "my number", expansion: "(720) 555-0134")
        let data = try JSONEncoder().encode([original])
        let restored = try JSONDecoder().decode([DictionaryEntry].self, from: data)
        XCTAssertEqual(restored.first, original)
    }
}
