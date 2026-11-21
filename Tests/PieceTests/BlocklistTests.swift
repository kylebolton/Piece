import XCTest
@testable import Piece

final class BlocklistTests: XCTestCase {
    private var folder: URL!
    private var session: KTSession!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("blocklist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("state"), withIntermediateDirectories: true)
        let settings = KTSessionSettings()
        settings.listenPort = 0
        settings.enableDHT = false
        settings.enableLSD = false
        settings.enablePortMapping = false
        session = KTSession(stateDirectory: folder.appendingPathComponent("state").path, settings: settings)
    }

    override func tearDown() {
        session.shutdown()
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, as name: String = "list.txt") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func shell(_ tool: String, _ args: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = directory ?? folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("\(tool) isn't available here.") }
    }

    // MARK: - Parsing

    func testParsesPeerGuardianLines() throws {
        let list = try write("""
        # a comment
        Some Org:1.2.3.4-1.2.3.9
        Name: with colons:10.0.0.0-10.0.0.255
        China Internet Network Information Center, CNNIC:1.2.0.0-1.2.255.255

        not a rule at all
        """)
        XCTAssertEqual(session.loadBlocklist(atPath: list.path), 3)
    }

    func testParsesEMuleDatAndSkipsAllowedRanges() throws {
        let list = try write("""
        001.002.003.004 - 001.002.003.255 , 000 , Blocked
        010.000.000.000 - 010.000.000.255 , 200 , Allowed by access level
        """)
        XCTAssertEqual(session.loadBlocklist(atPath: list.path), 1)
    }

    func testParsesBareRangesCIDRAndSingleAddresses() throws {
        let list = try write("""
        1.2.3.4-1.2.3.9
        192.168.0.0/16
        8.8.8.8
        2001:db8::/32
        Some v6:2001:db8:1::1-2001:db8:1::ff
        9.9.9.9/33
        300.1.1.1-300.1.1.9
        """)
        XCTAssertEqual(session.loadBlocklist(atPath: list.path), 5)
    }

    func testListWithoutRulesIsReportedAndMissingFileFails() throws {
        let empty = try write("# nothing here\n")
        XCTAssertEqual(session.loadBlocklist(atPath: empty.path), 0)
        XCTAssertEqual(session.loadBlocklist(atPath: folder.appendingPathComponent("missing").path), -1)
    }

    func testLargeListLoads() throws {
        var text = ""
        for i in 0..<200_000 {
            text += "Org \(i):\(i >> 16 & 255).\(i >> 8 & 255).\(i & 255).0-\(i >> 16 & 255).\(i >> 8 & 255).\(i & 255).255\n"
        }
        let list = try write(text)
        XCTAssertEqual(session.loadBlocklist(atPath: list.path), 200_000)
    }

    // MARK: - Unpacking

    func testDetectsPackingFromContent() {
        XCTAssertEqual(Blocklist.packing(of: Data([0x1F, 0x8B, 8, 0])), .gzip)
        XCTAssertEqual(Blocklist.packing(of: Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])), .xz)
        XCTAssertEqual(Blocklist.packing(of: Data("BZh9".utf8)), .bzip2)
        XCTAssertEqual(Blocklist.packing(of: Data([0x50, 0x4B, 3, 4])), .zip)
        XCTAssertEqual(Blocklist.packing(of: Data("Org:1.2.3.4-1.2.3.5".utf8)), .plain)
        XCTAssertEqual(Blocklist.packing(of: Data()), .plain)
    }

    private let sample = "Org:1.2.3.4-1.2.3.9\nOther:10.0.0.0-10.0.0.255\n"

    private func assertUnpacks(_ packed: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let out = folder.appendingPathComponent("out.txt")
        try await Blocklist.unpack(packed, to: out)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), sample, file: file, line: line)
        XCTAssertEqual(session.loadBlocklist(atPath: out.path), 2, file: file, line: line)
    }

    func testUnpacksPlainText() async throws {
        try await assertUnpacks(try write(sample))
    }

    func testUnpacksGzip() async throws {
        _ = try write(sample)
        try shell("/usr/bin/gzip", ["-k", "list.txt"])
        try await assertUnpacks(folder.appendingPathComponent("list.txt.gz"))
    }

    func testUnpacksBzip2() async throws {
        _ = try write(sample)
        try shell("/usr/bin/bzip2", ["-k", "list.txt"])
        try await assertUnpacks(folder.appendingPathComponent("list.txt.bz2"))
    }

    func testUnpacksZip() async throws {
        _ = try write(sample)
        try shell("/usr/bin/zip", ["-q", "list.zip", "list.txt"])
        try await assertUnpacks(folder.appendingPathComponent("list.zip"))
    }

    /// macOS ships no xz command, so the test makes its archive with one from Homebrew if there is one.
    func testUnpacksXZ() async throws {
        _ = try write(sample)
        let xz = ["/opt/homebrew/bin/xz", "/usr/local/bin/xz"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let xz else { throw XCTSkip("No xz command to make a test archive with.") }
        try shell(xz, ["-k", "list.txt"])
        try await assertUnpacks(folder.appendingPathComponent("list.txt.xz"))
    }

    func testCorruptArchiveThrows() async throws {
        let bad = folder.appendingPathComponent("bad.gz")
        try Data([0x1F, 0x8B, 0x08, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]).write(to: bad)
        do {
            try await Blocklist.unpack(bad, to: folder.appendingPathComponent("out.txt"))
            XCTFail("Expected an error")
        } catch is Blocklist.BlocklistError {
        }
    }

    func testUnsupportedPackingThrows() async throws {
        let zst = folder.appendingPathComponent("l.zst")
        try Data([0x28, 0xB5, 0x2F, 0xFD, 0, 0, 0, 0]).write(to: zst)
        do {
            try await Blocklist.unpack(zst, to: folder.appendingPathComponent("out.txt"))
            XCTFail("Expected an error")
        } catch is Blocklist.BlocklistError {
        }
    }
}
