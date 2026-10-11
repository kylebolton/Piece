import XCTest
@testable import Piece

final class StorageTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Compressible text bigger than one chunk, so chunk boundaries are exercised.
    private func makeText(_ name: String, megabytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let line = Data("The quick brown fox jumps over the lazy dog 0123456789\n".utf8)
        var data = Data()
        while data.count < megabytes * 1024 * 1024 { data.append(line) }
        try data.write(to: url)
        return url
    }

    private func makeRandom(_ name: String, bytes: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var generator = SystemRandomNumberGenerator()
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
        return url
    }

    func testPackRoundTripIsByteIdentical() throws {
        let text = try makeText("a.txt", megabytes: 9)
        let noise = try makeRandom("b.bin", bytes: 300_000)
        let pack = folder.appendingPathComponent("x.piecepack")
        let manifest = try PackFormat.pack(files: [(text, "a.txt"), (noise, "b.bin")], to: pack)
        XCTAssertEqual(manifest.files.map(\.name), ["a.txt", "b.bin"])
        XCTAssertLessThan(try pack.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 1_000_000 + 300_000 + 4096)

        let out = folder.appendingPathComponent("out", isDirectory: true)
        try PackFormat.unpack(pack, destination: { out.appendingPathComponent($0) })
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a.txt")), try Data(contentsOf: text))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("b.bin")), try Data(contentsOf: noise))
    }

    func testCorruptPackIsRejectedAndLeavesNothing() throws {
        let text = try makeText("a.txt", megabytes: 5)
        let pack = folder.appendingPathComponent("x.piecepack")
        _ = try PackFormat.pack(files: [(text, "a.txt")], to: pack)
        var bytes = try Data(contentsOf: pack)
        bytes[bytes.count / 3] ^= 0xFF
        try bytes.write(to: pack)
        let out = folder.appendingPathComponent("restored.txt")
        XCTAssertThrowsError(try PackFormat.unpack(pack, destination: { _ in out }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testCancelledPackLeavesNoFile() throws {
        let text = try makeText("a.txt", megabytes: 9)
        let pack = folder.appendingPathComponent("x.piecepack")
        XCTAssertThrowsError(try PackFormat.pack(files: [(text, "a.txt")], to: pack, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.appendingPathExtension("partial").path))
    }

    func testIncompressibleFilesAreSkipped() throws {
        XCTAssertFalse(CompressionService.isWorthCompressing(try makeRandom("n.bin", bytes: 3_000_000)))
        XCTAssertTrue(CompressionService.isWorthCompressing(try makeText("t.txt", megabytes: 3)))
        XCTAssertFalse(CompressionService.isWorthCompressing(try makeText("small.txt", megabytes: 0)))
    }

    func testTransparentCompressionKeepsContentAndShrinksDisk() throws {
        let text = try makeText("t.txt", megabytes: 12)
        let original = try Data(contentsOf: text)
        let before = CompressionService.allocatedSize(text)
        let saved = try CompressionService.compressInPlace(text)
        XCTAssertGreaterThan(saved, 0)
        XCTAssertLessThan(CompressionService.allocatedSize(text), before)
        XCTAssertEqual(try Data(contentsOf: text), original)
    }
}
