import XCTest
@testable import Piece

/// Downloads the pinned Jackett, runs it and searches through it. Needs the network (about 50 MB) and port 19117:
/// `TEST_RUNNER_KT_LIVE_JACKETT=1 xcodebuild test …`
@MainActor
final class JackettLiveTests: XCTestCase {
    func testBuiltInIndexersEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["KT_LIVE_JACKETT"] != nil else { throw XCTSkip("Set KT_LIVE_JACKETT=1 to run.") }
        // Indexer choices live in the app's real preferences; start from the defaults and leave nothing behind.
        UserDefaults.standard.removeObject(forKey: "jackettIndexers")
        let manager = JackettManager.shared
        defer {
            manager.stop()
            UserDefaults.standard.removeObject(forKey: "jackettIndexers")
        }
        let arch = ProcessInfo.processInfo.machineHardwareName
        XCTAssertNotNil(Bundle.main.url(forResource: "Jackett-\(JackettManager.version)-\(arch)", withExtension: "tar.gz",
                                        subdirectory: "Jackett"), "Jackett should be embedded in the app (run scripts/fetch-jackett.sh)")

        try await manager.ensureRunning()
        XCTAssertEqual(manager.state, .ready)
        XCTAssertNotNil(manager.apiKey)
        XCTAssertGreaterThan(manager.catalog.count, 50, "public indexer catalog")
        XCTAssertEqual(Set(manager.catalog.filter(\.isEnabled).map(\.id)), Set(JackettManager.defaultIndexers))
        XCTAssertGreaterThanOrEqual(JackettManager.defaultIndexers.count, 10)

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

/// A leftover helper from an earlier run (crash, force quit) is found by its path and stopped; others are left alone.
final class JackettLeftoverTests: XCTestCase {
    func testStopsLeftoverByPathOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("jackett")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)

        let leftover = Process()
        leftover.executableURL = binary
        leftover.arguments = ["60"]
        try leftover.run()
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["60"]
        try bystander.run()
        defer { leftover.terminate(); bystander.terminate() }

        XCTAssertEqual(JackettManager.runningPIDs(of: binary), [leftover.processIdentifier])
        await JackettManager.stopLeftovers(of: binary)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(leftover.isRunning)
        XCTAssertTrue(bystander.isRunning)
        XCTAssertEqual(JackettManager.runningPIDs(of: binary), [])
    }
}

private extension ProcessInfo {
    /// "arm64" or "x86_64", matching the embedded archive names (the test host runs as this slice).
    var machineHardwareName: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
