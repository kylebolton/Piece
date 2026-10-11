import XCTest
@testable import KTorrent

/// Downloads the pinned Jackett, runs it and searches through it. Needs the network (about 50 MB) and port 19117:
/// `TEST_RUNNER_KT_LIVE_JACKETT=1 xcodebuild test …`
@MainActor
final class JackettLiveTests: XCTestCase {
    func testBuiltInIndexersEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["KT_LIVE_JACKETT"] != nil else { throw XCTSkip("Set KT_LIVE_JACKETT=1 to run.") }
        let manager = JackettManager.shared
        defer { manager.stop() }

        try await manager.ensureRunning()
        XCTAssertEqual(manager.state, .ready)
        XCTAssertNotNil(manager.apiKey)
        XCTAssertGreaterThan(manager.catalog.count, 50, "public indexer catalog")
        XCTAssertEqual(Set(manager.catalog.filter(\.isEnabled).map(\.id)), Set(JackettManager.defaultIndexers))

        let provider = try XCTUnwrap(SearchStore.builtIn.first { $0.id == JackettManager.providerID })
        let results = try await SearchEngine.search("debian", provider: provider)
        print("LIVE Jackett \(results.count) results; first: \(results.first?.title ?? "-") seeders=\(results.first?.seeders.map(String.init) ?? "-")")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { $0.magnet != nil || $0.torrentURL != nil })
        XCTAssertTrue(results.contains { ($0.seeders ?? 0) > 0 })

        // Toggling an indexer off removes it; a second ensureRunning reuses the running instance.
        await manager.setIndexer("linuxtracker", enabled: false)
        XCTAssertFalse(manager.catalog.first { $0.id == "linuxtracker" }?.isEnabled ?? true)
        await manager.setIndexer("linuxtracker", enabled: true)
        try await manager.ensureRunning()
    }
}
