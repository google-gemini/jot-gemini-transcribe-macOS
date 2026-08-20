import XCTest
@testable import JotCore

/// The `smartFormatting` → two-flag migration. The interesting case is telling a
/// deliberate verbatim user apart from someone the app auto-degraded, because the
/// stored boolean is `false` for both and getting it wrong either strands a user
/// on verbatim forever or silently turns formatting on for someone who turned it off.
final class FormattingSettingsMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "jot.migration.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func migrate() { FormattingSettingsMigration.runIfNeeded(defaults: defaults) }
    private var smart: Bool? { defaults.object(forKey: "smartTranscription") as? Bool }
    private var cleanup: Bool? { defaults.object(forKey: "smartCleanupPass") as? Bool }

    /// The overwhelming majority: never opened Settings.
    func testUntouchedUserGetsNativeSmart() {
        migrate()
        XCTAssertEqual(smart, true)
        XCTAssertEqual(cleanup, false)
    }

    /// They wanted smart output. Native smart is now how that happens — they do
    /// not need the second model to get it.
    func testExplicitlyOnGetsNativeSmartWithoutTheExtraPass() {
        defaults.set(true, forKey: "smartFormatting")
        migrate()
        XCTAssertEqual(smart, true)
        XCTAssertEqual(cleanup, false)
    }

    /// `false` with no trips on the clock is a deliberate choice. Respect it —
    /// silently switching formatting back on is the same violation as silently
    /// switching it off.
    func testDeliberateVerbatimUserIsPreserved() {
        defaults.set(false, forKey: "smartFormatting")
        migrate()
        XCTAssertEqual(smart, false, "never silently re-enable formatting for someone who disabled it")
        XCTAssertEqual(cleanup, false)
    }

    /// `false` WITH trips still inside the 24h window is the auto-degrade
    /// fingerprint — a deliberate re-enable clears the array, so trips surviving
    /// means the app turned it off, not the user. They were degraded because the
    /// cleanup MODEL misbehaved; native smart is a different mechanism.
    func testAutoDegradedUserIsRestoredWithACleanSlate() {
        defaults.set(false, forKey: "smartFormatting")
        // Three is the exact trigger: auto-degrade fired the moment the array
        // reached 3, so this is the state it leaves behind.
        defaults.set([Date(), Date(), Date()], forKey: "gateTrips")
        migrate()
        XCTAssertEqual(smart, true, "the degrade was about the cleanup model, not about native smart")
        XCTAssertEqual(cleanup, false)
        XCTAssertNil(defaults.array(forKey: "gateTrips"),
                     "stale trips would instantly re-degrade the restored user")
        XCTAssertTrue(defaults.bool(forKey: "shouldAnnounceSmartRestored"),
                      "un-degrading silently is the same sin as degrading silently")
    }

    /// The boundary case, and the one that matters most.
    ///
    /// The OLD setSmartFormatting cleared gateTrips only when ENABLING, so a user
    /// who deliberately picked verbatim keeps whatever trips they had accumulated
    /// — at most 2, since the 3rd is what triggers auto-degrade. Treating "any
    /// surviving trip" as the fingerprint would flip those users back to smart
    /// and congratulate them for it.
    func testTwoTripsIsAUserChoiceNotAnAutoDegrade() {
        defaults.set(false, forKey: "smartFormatting")
        defaults.set([Date(), Date()], forKey: "gateTrips")
        migrate()
        XCTAssertEqual(smart, false, "fewer than 3 trips means the USER disabled it")
        XCTAssertFalse(defaults.bool(forKey: "shouldAnnounceSmartRestored"),
                       "nothing was restored, so nothing should be announced")
    }

    /// Stale trips still count once there are 3 of them — the alternative is
    /// stranding a degraded user on verbatim forever, which is the worse error.
    func testOldTripsStillCountWhenThereAreThree() {
        defaults.set(false, forKey: "smartFormatting")
        let old = Date(timeIntervalSinceNow: -200_000)
        defaults.set([old, old, old], forKey: "gateTrips")
        migrate()
        XCTAssertEqual(smart, true)
    }

    func testRetiresTheOldKeyAndIsIdempotent() {
        defaults.set(false, forKey: "smartFormatting")
        migrate()
        XCTAssertNil(defaults.object(forKey: "smartFormatting"),
                     "a lingering key is a second source of truth for something it no longer controls")

        // A later flip must survive a second run (e.g. downgrade then upgrade).
        defaults.set(true, forKey: "smartTranscription")
        migrate()
        XCTAssertEqual(smart, true, "migration must not re-run against a stale value")
    }
}

final class SanitizedVocabularyTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "dictionaryEntries") }

    /// Dictionary entries are user/CSV data. A term carrying a newline could
    /// otherwise smuggle its own instruction line into the cleanup prompt (audit L31),
    /// and the same sanitizer now guards the transcription request.
    func testStripsNewlinesAndCapsLength() {
        _ = store.add(term: "Borg\nmon", misspelling: nil)
        _ = store.add(term: String(repeating: "x", count: 80), misspelling: nil)
        let vocabulary = store.sanitizedVocabulary()
        XCTAssertFalse(vocabulary.contains { $0.contains("\n") })
        XCTAssertTrue(vocabulary.allSatisfy { $0.count <= 60 })
    }

    /// Truncation drops from the END of the sorted list, and vocabulary() sorts
    /// starred first — so the terms the user explicitly prioritised survive a
    /// byte-ceiling trim.
    func testByteCeilingKeepsStarredTerms() {
        for index in 0..<60 { _ = store.add(term: "term-number-\(index)", misspelling: nil) }
        _ = store.add(term: "Kubernetes", misspelling: nil)
        if let starred = store.entries().first(where: { $0.term == "Kubernetes" }) {
            store.toggleStar(id: starred.id)
        }
        let vocabulary = store.sanitizedVocabulary(maxBytes: 60)
        XCTAssertTrue(vocabulary.contains("Kubernetes"), "starred terms must survive the trim")
        XCTAssertLessThanOrEqual(vocabulary.joined(separator: ",").utf8.count, 60)
    }

    /// Never send misspellings. Biasing a recogniser toward "cooper netties" is
    /// actively harmful, and spellings() sits close enough to wire up by accident.
    func testCarriesOnlyCorrectTermsNeverMisspellings() {
        _ = store.add(term: "Kubernetes", misspelling: "cooper netties")
        let vocabulary = store.sanitizedVocabulary()
        XCTAssertTrue(vocabulary.contains("Kubernetes"))
        XCTAssertFalse(vocabulary.contains("cooper netties"))
    }
}
