import XCTest
@testable import ContinuityCore

final class CatalogAutocorrectTests: XCTestCase {

    private func engine() -> CatalogAutocorrect {
        var ac = CatalogAutocorrect()
        ac.learn(phrases: [
            "Blinding Lights", "The Weeknd", "After Hours",
            "Starboy", "Save Your Tears", "The Weeknd",   // weeknd twice → heavier
            "Beyoncé", "Renaissance",
        ])
        return ac
    }

    func testTokenizationLowercasesStripsPunctuationAndDropsSingles() {
        XCTAssertEqual(CatalogAutocorrect.words(in: "Don't Stop (Remix) - A B4U!"),
                       ["don't", "stop", "remix", "b4u"])
    }

    func testPrefixCompletionsRankAboveRepairs() {
        let ac = engine()
        XCTAssertEqual(ac.suggestions(for: "wee").first, "weeknd")
    }

    func testSuggestionsRepairCloseMisspelling() {
        let ac = engine()
        XCTAssertTrue(ac.suggestions(for: "weekend").contains("weeknd"))
    }

    func testCorrectionFiresOnlyForUnknownWords() {
        let ac = engine()
        // "weeknd" is in the vocabulary — a catalog word must never be "corrected".
        XCTAssertNil(ac.correction(for: "weeknd"))
        // One edit away from a known word → confident repair.
        XCTAssertEqual(ac.correction(for: "weekndd"), "weeknd")
        // Nowhere near anything known → leave the user's word alone.
        XCTAssertNil(ac.correction(for: "zzzzzz"))
    }

    func testHeavierWordWinsCorrectionTies() {
        var ac = CatalogAutocorrect()
        ac.learn(phrases: ["cars"], weight: 1)
        ac.learn(phrases: ["care"], weight: 5)
        XCTAssertEqual(ac.correction(for: "carz"), "care")
    }

    func testEditDistanceBoundedEarlyOut() {
        XCTAssertEqual(CatalogAutocorrect.editDistance("abc", "abc", limit: 1), 0)
        XCTAssertEqual(CatalogAutocorrect.editDistance("abc", "abd", limit: 1), 1)
        XCTAssertGreaterThan(CatalogAutocorrect.editDistance("abcdef", "zyxwvu", limit: 2), 2)
        XCTAssertEqual(CatalogAutocorrect.editDistance("", "ab", limit: 2), 2)
    }
}
