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

/// The settings live-audit contract: every write announces itself, so runtime
/// surfaces can re-render the moment a toggle flips (dogfood: "I turned the
/// resting indicator on and off and it didn't work").
final class SettingsLiveUpdateTests: XCTestCase {
    private let settings = SettingsStore()

    override func tearDown() {
        for key in ["showIdleIndicator", "soundsEnabled", "doubleTapLock", "gateTrips",
                    "experimentalNoiseHandling", "smartTranscription", "smartCleanupPass",
                    "legacyTranscribeEndpoint"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func expectChange(forKey key: String, during action: () -> Void) {
        let posted = expectation(description: "gtSettingDidChange(\(key))")
        let observer = NotificationCenter.default.addObserver(
            forName: .gtSettingDidChange, object: nil, queue: nil
        ) { note in
            if note.object as? String == key {
                posted.fulfill()
            }
        }
        action()
        wait(for: [posted], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }

    func testEverySetterPostsItsKey() {
        expectChange(forKey: "showIdleIndicator") { settings.setShowIdleIndicator(false) }
        expectChange(forKey: "soundsEnabled") { settings.setSoundsEnabled(false) }
        expectChange(forKey: "smartTranscription") { settings.setSmartTranscription(false) }
        expectChange(forKey: "smartCleanupPass") { settings.setSmartCleanupPass(false) }
        expectChange(forKey: "legacyTranscribeEndpoint") { settings.setLegacyTranscribeEndpoint(true) }
        expectChange(forKey: "doubleTapLock") { settings.setDoubleTapLock(true) }
        expectChange(forKey: "hotkeyKey") { settings.setHotkeyKey(.fn) }
        expectChange(forKey: "audioRetentionDays") { settings.setAudioRetentionDays(7) }
        expectChange(forKey: "experimentalNoiseHandling") { settings.setExperimentalNoiseHandling(true) }
    }

    func testManualReEnableClearsGateTrips() {
        // Three trips inside the window = degraded.
        _ = settings.recordGateTrip()
        _ = settings.recordGateTrip()
        XCTAssertEqual(settings.recordGateTrip(), 3)
        // The user deliberately re-enables the tone pass: the slate must be clean,
        // or a single further trip instantly re-degrades and their choice loses.
        // (This clear moved from setSmartFormatting when auto-degrade re-pointed
        // at the opt-in pass — if it had not moved, this test would still pass on
        // the old key while the real behaviour silently regressed.)
        settings.setSmartCleanupPass(true)
        XCTAssertEqual(settings.recordGateTrip(), 1)
    }
}

final class DictionaryImportTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
    }

    func testHeaderRowIsDropped() {
        XCTAssertEqual(store.importCSV("term,misspelling\nKubernetes,cooper netties"), 1)
        XCTAssertEqual(store.entries().map(\.term), ["Kubernetes"])
    }

    func testHeaderlessFirstRowStartingWithTermIsKept() {
        // "terminal" hasPrefix("term") — the old sniff ate this real entry.
        XCTAssertEqual(store.importCSV("terminal,termie\nKubernetes,"), 2)
        XCTAssertEqual(store.entries().map(\.term), ["terminal", "Kubernetes"])
    }

    func testImportDedupesAgainstExistingAndItself() {
        _ = store.add(term: "Gemini")
        let count = store.importCSV("gemini,\nGemini,\nVeo,\nveo,")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.entries().map(\.term), ["Gemini", "Veo"])
    }

    func testSpellingsPrioritizeStarred() {
        for i in 0..<12 {
            _ = store.add(term: "term\(i)", misspelling: "wrong\(i)")
        }
        // Star the OLDEST entry — insertion order would leave it last.
        let oldest = store.entries().first!
        store.toggleStar(id: oldest.id)
        let spellings = store.spellings()
        XCTAssertEqual(spellings.count, 10)
        XCTAssertEqual(spellings.first?.right, oldest.term,
                       "starred entries must lead the prompt's spelling hints")
    }
}
