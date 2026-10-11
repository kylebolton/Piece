import AVFoundation
import XCTest
@testable import Piece

/// Exercises the real libtorrent session, the stream server and ffmpeg together, without touching the network.
final class IntegrationTests: XCTestCase {
    private var folder: URL!
    private var session: KTSession!
    private var server: StreamServer!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("kt-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("state"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        let settings = KTSessionSettings()
        settings.listenPort = 0
        settings.enableDHT = false
        settings.enableLSD = false
        settings.enablePortMapping = false
        session = KTSession(stateDirectory: folder.appendingPathComponent("state").path, settings: settings)
        server = StreamServer(session: session)
        server.start()
        XCTAssertGreaterThan(server.port, 0)
    }

    override func tearDown() {
        session.shutdown()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Adds a file that already exists on disk and waits for libtorrent to verify it.
    private func seed(_ file: URL) throws -> String {
        let torrent = try XCTUnwrap(KTSession.createTorrent(forPath: file.path))
        let hash = try session.addTorrentData(torrent, savePath: file.deletingLastPathComponent().path)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let status = session.statuses().first(where: { $0.infoHash == hash }), status.state == .seeding { return hash }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Torrent never finished checking")
        return hash
    }

    func testHLSFilesHonourRangeRequests() async throws {
        let directory = folder.appendingPathComponent("hls", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        try payload.write(to: directory.appendingPathComponent("init.mp4"))
        server.registerHLS(id: "test", directory: directory)
        let url = server.hlsURL(sessionID: "test", file: "init.mp4")
        let local = URL(string: url.absoluteString.replacingOccurrences(of: url.host ?? "", with: "127.0.0.1"))!

        var request = URLRequest(url: local)
        request.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (part, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 100-199/1000")
        XCTAssertEqual(part, payload.subdata(in: 100..<200))

        let (whole, wholeResponse) = try await URLSession.shared.data(from: local)
        XCTAssertEqual((wholeResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((wholeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(whole, payload)
    }

    func testStreamsTorrentFileWithRanges() async throws {
        var bytes = [UInt8](repeating: 0, count: 3_000_000)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index / 255) }
        let payload = Data(bytes)
        let file = folder.appendingPathComponent("data/movie.mp4")
        try payload.write(to: file)
        let hash = try seed(file)

        XCTAssertEqual(session.files(forTorrent: hash).map(\.path), ["movie.mp4"])
        XCTAssertEqual(session.contiguousBytes(inTorrent: hash, file: 0, offset: 0), 3_000_000)
        XCTAssertEqual(session.contiguousBytes(inTorrent: hash, file: 0, offset: 2_999_990), 10)
        XCTAssertTrue(session.pieceMap(forTorrent: hash).allSatisfy { $0 == 1 })

        let url = server.torrentFileURL(hash: hash, fileIndex: 0, name: "movie.mp4", loopback: true)

        let (whole, wholeResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((wholeResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(whole, payload)

        var ranged = URLRequest(url: url)
        ranged.setValue("bytes=1000000-1000099", forHTTPHeaderField: "Range")
        let (part, partResponse) = try await URLSession.shared.data(for: ranged)
        let http = try XCTUnwrap(partResponse as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 1000000-1000099/3000000")
        XCTAssertEqual(part, payload.subdata(in: 1_000_000..<1_000_100))

        var tail = URLRequest(url: url)
        tail.setValue("bytes=-16", forHTTPHeaderField: "Range")
        let (suffix, _) = try await URLSession.shared.data(for: tail)
        XCTAssertEqual(suffix, payload.suffix(16))

        // The path token keeps other devices on the network out.
        let forged = URL(string: url.absoluteString.replacingOccurrences(of: server.token, with: "0000"))!
        let (_, forgedResponse) = try await URLSession.shared.data(from: forged)
        XCTAssertEqual((forgedResponse as? HTTPURLResponse)?.statusCode, 404)

        XCTAssertNotNil(session.magnetLink(forTorrent: hash))
        session.removeTorrent(hash, deleteFiles: false)
        XCTAssertTrue(session.statuses().isEmpty)
    }

    func testConvertsMKVToPlayableHLSWithSubtitles() async throws {
        let ffmpeg = try XCTUnwrap(AppPaths.helper("ffmpeg"), "ffmpeg helper missing")
        let source = folder.appendingPathComponent("data/clip.mkv")
        // An MPEG-4 Part 2 + MP3-less clip AVPlayer can't open by itself.
        let made = await ProcessRunner.run(ffmpeg, [
            "-v", "error", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "320x240", "-r", "24", "-i", "/dev/zero",
            "-f", "s16le", "-ar", "48000", "-ac", "2", "-i", "/dev/zero",
            "-t", "8", "-c:v", "mpeg4", "-c:a", "ac3", "-y", source.path,
        ])
        XCTAssertEqual(made?.status, 0, made?.stderr ?? "")
        let hash = try seed(source)

        // Probe and convert through the stream server, as happens for a file that's still downloading.
        let input = server.torrentFileURL(hash: hash, fileIndex: 0, name: "clip.mkv", loopback: true).absoluteString
        let probed = await MediaProbe.probe(input)
        let probe = try XCTUnwrap(probed)
        XCTAssertEqual(probe.video?.codec, "mpeg4")
        XCTAssertEqual(probe.audio.first?.codec, "ac3")
        XCTAssertEqual(probe.duration, 8, accuracy: 0.5)

        let hls = HLSSession(server: server)
        defer { hls.stop() }
        let cues = [SubtitleCue(start: 1, end: 3, text: "Hello"), SubtitleCue(start: 4, end: 6, text: "World")]
        XCTAssertTrue(hls.start(input: input, probe: probe, subtitles: (name: "English", language: "en", cues: cues)))

        let (master, _) = try await URLSession.shared.data(from: hls.masterURL)
        XCTAssertTrue(String(decoding: master, as: UTF8.self).contains("subs.m3u8"))

        // The media playlist request blocks until ffmpeg has produced its first segment.
        let (media, mediaResponse) = try await URLSession.shared.data(from: server.hlsURL(sessionID: hls.id, file: "media.m3u8"))
        XCTAssertEqual((mediaResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: media, as: UTF8.self).contains("init.mp4"), hls.log)

        let (vtt, _) = try await URLSession.shared.data(from: server.hlsURL(sessionID: hls.id, file: "subs.vtt"))
        XCTAssertTrue(String(decoding: vtt, as: UTF8.self).contains("00:00:01.000 --> 00:00:03.000\nHello"))

        // AVFoundation must accept the result, including the subtitle rendition AirPlay receivers use.
        let asset = AVURLAsset(url: hls.masterURL)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let legible = try await asset.loadMediaSelectionGroup(for: .legible)
        XCTAssertEqual(legible?.options.count, 1)

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        let deadline = Date().addingTimeInterval(20)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(item.status, .readyToPlay, item.error?.localizedDescription ?? hls.log)
        while player.currentTime().seconds < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 1, "Playback never advanced")
        player.pause()
    }

    func testResumeDataSurvivesRestart() throws {
        let file = folder.appendingPathComponent("data/notes.txt")
        try Data(repeating: 7, count: 200_000).write(to: file)
        let hash = try seed(file)
        session.shutdown()

        let settings = KTSessionSettings()
        settings.listenPort = 0
        settings.enableDHT = false
        session = KTSession(stateDirectory: folder.appendingPathComponent("state").path, settings: settings)
        session.restoreTorrents()
        XCTAssertEqual(session.statuses().map(\.infoHash), [hash])
    }
}
