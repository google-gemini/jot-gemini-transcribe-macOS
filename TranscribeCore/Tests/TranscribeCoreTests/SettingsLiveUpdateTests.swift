import XCTest
@testable import TranscribeCore

/// The settings live-audit contract: every write announces itself, so runtime
/// surfaces can re-render the moment a toggle flips (dogfood: "I turned the
/// resting indicator on and off and it didn't work").
final class SettingsLiveUpdateTests: XCTestCase {
    private let settings = SettingsStore()

    override func tearDown() {
        for key in ["showIdleIndicator", "soundsEnabled", "smartFormatting", "doubleTapLock", "gateTrips"] {
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
        expectChange(forKey: "smartFormatting") { settings.setSmartFormatting(false) }
        expectChange(forKey: "doubleTapLock") { settings.setDoubleTapLock(true) }
        expectChange(forKey: "hotkeyKey") { settings.setHotkeyKey(.fn) }
        expectChange(forKey: "audioRetentionDays") { settings.setAudioRetentionDays(7) }
    }

    func testManualReEnableClearsGateTrips() {
        // Three trips inside the window = degraded.
        _ = settings.recordGateTrip()
        _ = settings.recordGateTrip()
        XCTAssertEqual(settings.recordGateTrip(), 3)
        // The user deliberately re-enables: the slate must be clean, or a single
        // further trip instantly re-degrades and their choice silently loses.
        settings.setSmartFormatting(true)
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
