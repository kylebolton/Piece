import XCTest
@testable import Piece

/// Checks the built-in TMDB and OpenSubtitles keys against the real services. Needs the network:
/// `TEST_RUNNER_KT_LIVE_KEYS=1 xcodebuild test …`
final class BuiltInKeysLiveTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["KT_LIVE_KEYS"] != nil else { throw XCTSkip("Set KT_LIVE_KEYS=1 to run.") }
    }

    func testTMDBKey() async throws {
        try requireLive()
        XCTAssertTrue(MetadataService.hasTMDB)
        let matches = await MetadataService.filmCandidates(query: "Big Buck Bunny")
        print("LIVE TMDB \(matches.map(\.source).first ?? "none") \(matches.count) results; first: \(matches.first?.title ?? "-") poster=\(matches.first?.posterURL != nil)")
        XCTAssertEqual(matches.first?.source, "tmdb")
        XCTAssertNotNil(matches.first?.posterURL)
    }

    func testOpenSubtitlesKey() async throws {
        try requireLive()
        let results = try await OpenSubtitles.shared.search(query: "big buck bunny", movieHash: nil, languages: ["en"])
        print("LIVE OpenSubtitles \(results.count) results; first: \(results.first?.release ?? "-")")
        XCTAssertFalse(results.isEmpty)
    }
}
