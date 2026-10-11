import XCTest
@testable import KTorrent

/// Runs the site detector against real websites. Needs the network, so it only runs on request:
/// `TEST_RUNNER_KT_LIVE_SITES="linuxtracker.org,fosstorrents.com" xcodebuild test …`
final class LiveSiteTests: XCTestCase {
    func testDetectSites() async throws {
        guard let list = ProcessInfo.processInfo.environment["KT_LIVE_SITES"], !list.isEmpty else {
            throw XCTSkip("Set KT_LIVE_SITES to a comma-separated list of sites to probe.")
        }
        let query = ProcessInfo.processInfo.environment["KT_LIVE_QUERY"] ?? "ubuntu"
        for site in list.split(separator: ",").map(String.init) {
            print("LIVE ===== \(site)")
            let outcome = await SiteDetector.detect(input: site, testQuery: query) { print("LIVE   · \($0)") }
            guard let outcome else {
                print("LIVE   RESULT none")
                continue
            }
            let filled = await TrackerScraper.fill(outcome.sample)
            print("LIVE   RESULT \(outcome.provider.kind.rawValue) \(outcome.provider.url) → \(outcome.sample.count) results")
            for result in filled.prefix(6) {
                print("LIVE     \(result.title.prefix(60)) | size=\(result.size.map(Format.bytes) ?? "-") s=\(result.seeders.map(String.init) ?? "-") l=\(result.leechers.map(String.init) ?? "-") magnet=\(result.magnet != nil) torrent=\(result.torrentURL != nil) details=\(result.detailsURL != nil)")
            }
            if let first = outcome.sample.first, first.needsResolving {
                let link = try? await SearchEngine.resolve(first)
                print("LIVE     resolved → \(link?.prefix(70) ?? "nothing")")
            }
        }
    }
}
