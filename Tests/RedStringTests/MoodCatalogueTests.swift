import XCTest

/// The preset catalogue: identity, the one celebration, and search.
final class MoodCatalogueTests: XCTestCase {
    func testEveryGroupHasPresets() {
        for group in MoodGroup.allCases {
            XCTAssertFalse(group.moods.isEmpty, "\(group.rawValue) is empty")
        }
    }

    func testIDsAreUnique() {
        let ids = MoodGroup.allMoods.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "the picker highlights and seeds by id")
    }

    func testNoBlankEmojiOrLabel() {
        for mood in MoodGroup.allMoods {
            XCTAssertFalse(mood.emoji.isEmpty, "\(mood.label) has no emoji")
            XCTAssertFalse(mood.label.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertEqual(mood.emoji.count, 1, "\(mood.label): one emoji, or the tiles and widgets misalign")
        }
    }

    func testExactlyOneCelebration() {
        let celebrations = MoodGroup.allMoods.filter(\.isCelebration)
        XCTAssertEqual(celebrations.count, 1)
        XCTAssertEqual(MoodGroup.celebration, celebrations.first)
    }

    func testRequestedPresetsExist() {
        let labels = Set(MoodGroup.allMoods.map(\.label))
        XCTAssertTrue(labels.contains("playing cards"))
        XCTAssertTrue(labels.contains("begging for forgiveness"))
        XCTAssertTrue(labels.contains("eating a sandwich"))
    }

    func testSearchMatchesLabelCaseInsensitivelyAndEmoji() {
        let sandwich = MoodGroup.allMoods.first { $0.label == "eating a sandwich" }!
        XCTAssertTrue(sandwich.matches(""))
        XCTAssertTrue(sandwich.matches("  "))
        XCTAssertTrue(sandwich.matches("SANDWICH"))
        XCTAssertTrue(sandwich.matches("🥪"))
        XCTAssertFalse(sandwich.matches("ramen"))
    }
}
