import XCTest
@testable import Piece

@MainActor
final class TagAndSearchTests: XCTestCase {
    private func store() -> TagStore {
        TagStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString).json"))
    }

    func testCreateIsCaseInsensitiveAndStripsHash() {
        let tags = store()
        let first = tags.create(name: "#Favourites")
        XCTAssertEqual(tags.create(name: "favourites"), first)
        XCTAssertEqual(tags.tags.count, 1)
        XCTAssertNil(tags.create(name: "  # "))
    }

    func testAssignToggleAndDelete() {
        let tags = store()
        let tag = tags.create(name: "Kids")!
        tags.assign(tag, to: ["a", "b"])
        XCTAssertEqual(tags.count(of: tag), 2)
        tags.toggle(tag, on: ["a", "b"])
        XCTAssertEqual(tags.count(of: tag), 0)
        tags.assign(tag, to: ["a"])
        tags.delete(tag)
        XCTAssertTrue(tags.tags(for: "a").isEmpty)
    }

    func testPersistence() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString).json")
        let first = TagStore(fileURL: url)
        let tag = first.create(name: "Keep")!
        first.assign(tag, to: ["x"])
        first.saveNow()
        let second = TagStore(fileURL: url)
        XCTAssertEqual(second.tags(for: "x").map(\.name), ["Keep"])
    }

    func testSavedSearchesToggleDedupeAndPersist() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID().uuidString).json")
        let first = SavedSearchStore(fileURL: url)
        first.toggle("  Ubuntu 24.04 ")
        XCTAssertTrue(first.isSaved("ubuntu 24.04"))
        XCTAssertNil(first.add("   "))
        first.add("debian")
        first.add("DEBIAN")
        XCTAssertEqual(first.searches.map(\.query), ["debian", "Ubuntu 24.04"])
        let second = SavedSearchStore(fileURL: url)
        XCTAssertEqual(second.searches.count, 2)
        second.toggle("debian")
        XCTAssertFalse(second.isSaved("debian"))
    }

    func testQueryParsing() {
        let query = SearchQuery("Bat 2022 #kids")
        XCTAssertEqual(query.words, ["bat", "2022"])
        XCTAssertEqual(query.tagNames, ["kids"])
        XCTAssertTrue(SearchQuery("   ").isEmpty)
    }

    func testMatchingUsesWordPrefixesAndTags() {
        var item = MediaItem(kind: .film, path: "/x.mkv", title: "The Batman")
        item.year = 2022
        let kids = Tag(name: "Kids", colorIndex: 0)
        let withTag = SearchIndex.document(for: item, tags: [kids])
        let without = SearchIndex.document(for: item, tags: [])
        XCTAssertTrue(SearchIndex.matches(withTag, SearchQuery("bat 20")))
        XCTAssertFalse(SearchIndex.matches(withTag, SearchQuery("superman")))
        XCTAssertTrue(SearchIndex.matches(withTag, SearchQuery("#kid")))
        XCTAssertFalse(SearchIndex.matches(without, SearchQuery("#kids")))
        XCTAssertTrue(SearchIndex.matches(without, SearchQuery("")))
    }
}
