import CryptoKit
import Foundation

/// A public indexer Jackett knows how to search.
struct JackettIndexer: Identifiable, Hashable {
    var id: String
    var name: String
    var summary: String
    var language: String
    var isEnabled: Bool
}

/// Runs [Jackett](https://github.com/Jackett/Jackett) (GPL-2.0) as a private background helper so the app can search
/// hundreds of sites without the user installing or configuring anything. The pinned release ships inside the app
/// (scripts/fetch-jackett.sh) and is unpacked into the support folder on first launch; builds without it download the
/// same release instead, checked against its SHA-256. It listens on localhost only, never updates itself, and shuts
/// down when Piece quits.
@MainActor
@Observable
final class JackettManager {
    static let shared = JackettManager()

    nonisolated static let providerID = UUID(uuidString: "0A1C7C58-5B0B-4C1E-9C55-000000000003")!
    nonisolated static let port = 19117
    nonisolated static let version = "v0.24.2816"
    nonisolated static let searchURL = "http://127.0.0.1:\(port)/api/v2.0/indexers/all/results/torznab/api"
    /// Indexers switched on out of the box; the rest are one switch away in Sources.
    nonisolated static let defaultIndexers = [
        "internetarchive", "linuxtracker", "thepiratebay", "1337x", "yts", "eztv", "nyaasi", "limetorrents",
        "torrentgalaxyclone", "kickasstorrents-ws", "tokyotosho", "audiobookbay",
    ]

    #if arch(arm64)
    private static let asset = (name: "Jackett.Binaries.macOSARM64.tar.gz",
                                sha256: "f677e70ad76af0b9022478f1fcb37298b66a356cf9fbbdcf2c79c3941280fee5")
    #else
    private static let asset = (name: "Jackett.Binaries.macOS.tar.gz",
                                sha256: "4a44d0a3c86b8f0f7d3ab9c3b98534acbb2940d3d3c3c84a3cfb5aac5e87ceb9")
    #endif

    enum State: Equatable {
        case idle
        case downloading(Double)
        case starting
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The copy of Jackett embedded in the app for this Mac's architecture, if the build includes one.
    private static var bundledArchive: URL? {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return Bundle.main.url(forResource: "Jackett-\(version)-\(arch)", withExtension: "tar.gz", subdirectory: "Jackett")
    }
    private(set) var catalog: [JackettIndexer] = []

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var startTask: Task<Void, Error>?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let session: URLSession

    private var binary: URL { root.appendingPathComponent("bin/Jackett/jackett") }
    private var dataFolder: URL { root.appendingPathComponent("data", isDirectory: true) }
    private var base: URL { URL(string: "http://127.0.0.1:\(Self.port)")! }

    init(root: URL = AppPaths.directory("Jackett")) {
        self.root = root
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: configuration)
    }

    // MARK: - Public

    var statusText: String {
        switch state {
        case .idle: "Starts with your first search"
        case .downloading(let fraction): "Downloading search indexers… \(Int(fraction * 100))%"
        case .starting: "Starting…"
        case .ready: "\(enabledIDs.count) indexer\(enabledIDs.count == 1 ? "" : "s") on"
        case .failed(let message): message
        }
    }

    var enabledIDs: [String] {
        UserDefaults.standard.stringArray(forKey: "jackettIndexers") ?? Self.defaultIndexers
    }

    /// The key Jackett generated for its Torznab endpoint.
    var apiKey: String? {
        guard let data = try? Data(contentsOf: dataFolder.appendingPathComponent("ServerConfig.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["APIKey"] as? String
    }

    /// Installs (first time), starts and configures Jackett. Safe to call from several searches at once.
    func ensureRunning() async throws {
        if state == .ready, await isResponding() { return }
        if let startTask { return try await startTask.value }
        let task = Task { try await bringUp() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    func stop() {
        process?.terminate()
        process = nil
        if state == .ready || state == .starting { state = .idle }
    }

    func setIndexer(_ id: String, enabled: Bool) async {
        var ids = Set(enabledIDs)
        if enabled { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: "jackettIndexers")
        if let index = catalog.firstIndex(where: { $0.id == id }) { catalog[index].isEnabled = enabled }
        if state == .ready { try? await syncIndexers() }
    }

    // MARK: - Bring-up

    private func bringUp() async throws {
        do {
            if !(await isResponding()) {
                if !FileManager.default.isExecutableFile(atPath: binary.path) || installedVersion != Self.version {
                    try await install()
                }
                state = .starting
                try launch()
                try await waitUntilResponding()
            }
            state = .starting
            try await syncIndexers()
            state = .ready
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            throw error
        }
    }

    private var installedVersion: String? {
        try? String(contentsOf: root.appendingPathComponent("bin/.version"), encoding: .utf8)
    }

    private func install() async throws {
        let archive: URL
        var downloaded: URL?
        if let bundled = Self.bundledArchive {
            state = .starting
            archive = bundled
        } else {
            state = .downloading(0)
            let url = URL(string: "https://github.com/Jackett/Jackett/releases/download/\(Self.version)/\(Self.asset.name)")!
            let delegate = ProgressDelegate { [weak self] fraction in Task { @MainActor in self?.state = .downloading(fraction) } }
            let (file, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            downloaded = file
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JackettError.download }
            guard try Self.sha256(of: file) == Self.asset.sha256 else { throw JackettError.checksum }
            archive = file
        }
        defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded) } }

        let fm = FileManager.default
        let staging = root.appendingPathComponent("bin.tmp")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try await Self.untar(archive, into: staging)
        guard fm.fileExists(atPath: staging.appendingPathComponent("Jackett/jackett").path) else { throw JackettError.extract }
        try Self.version.write(to: staging.appendingPathComponent(".version"), atomically: true, encoding: .utf8)
        let destination = root.appendingPathComponent("bin")
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    /// Unpacks off the main actor; the archive is about 120 MB once expanded.
    private nonisolated static func untar(_ archive: URL, into folder: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let tar = Process()
                tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                tar.arguments = ["-xzf", archive.path, "-C", folder.path]
                do {
                    try tar.run()
                    tar.waitUntilExit()
                    if tar.terminationStatus == 0 { continuation.resume() } else { continuation.resume(throwing: JackettError.extract) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func launch() throws {
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let log = dataFolder.appendingPathComponent("jackett-stdout.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--Port", String(Self.port), "--DataFolder", dataFolder.path,
                             "--NoRestart", "--NoUpdates", "--ListenPrivate"]
        process.standardOutput = try? FileHandle(forWritingTo: log)
        process.standardError = process.standardOutput
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil
                if self.state == .ready { self.state = .idle }
            }
        }
        try process.run()
        self.process = process
    }

    private func waitUntilResponding() async throws {
        for _ in 0..<80 {
            if await isResponding() { return }
            if process?.isRunning == false { throw JackettError.exited }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw JackettError.timeout
    }

    private func isResponding() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("UI/Dashboard"), timeoutInterval: 3)
        request.httpMethod = "HEAD"
        return (try? await session.data(for: request))?.1 is HTTPURLResponse
    }

    // MARK: - Indexers

    /// Makes Jackett's configured indexers match the user's choices, and refreshes the catalog.
    private func syncIndexers() async throws {
        _ = try await get("UI/Dashboard")          // establishes the (password-less) UI session
        let all = try await listIndexers()
        let wanted = Set(enabledIDs)
        let configured = Set(all.filter(\.isEnabled).map(\.id))
        for id in wanted.subtracting(configured) where all.contains(where: { $0.id == id }) {
            _ = try? await send("api/v2.0/indexers/\(id)/config", method: "POST", body: Data("[]".utf8))
        }
        for id in configured.subtracting(wanted) {
            _ = try? await send("api/v2.0/indexers/\(id)", method: "DELETE")
        }
        catalog = all.map { var copy = $0; copy.isEnabled = wanted.contains($0.id); return copy }
    }

    func refreshCatalog() async {
        guard state == .ready, (try? await get("UI/Dashboard")) != nil, let all = try? await listIndexers() else { return }
        let wanted = Set(enabledIDs)
        catalog = all.map { var copy = $0; copy.isEnabled = wanted.contains($0.id); return copy }
    }

    private func listIndexers() async throws -> [JackettIndexer] {
        let data = try await get("api/v2.0/indexers")
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw JackettError.badReply }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String,
                  (item["type"] as? String) == "public" else { return nil }
            return JackettIndexer(id: id, name: name, summary: item["description"] as? String ?? "",
                                  language: item["language"] as? String ?? "",
                                  isEnabled: item["configured"] as? Bool ?? false)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func get(_ path: String) async throws -> Data { try await send(path, method: "GET") }

    @discardableResult
    private func send(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else { throw JackettError.badReply }
        return data
    }
}

enum JackettError: LocalizedError {
    case download, checksum, extract, exited, timeout, badReply

    var errorDescription: String? {
        switch self {
        case .download: "Couldn't download the search indexers. Check your connection and try again."
        case .checksum: "The downloaded indexer package didn't match its checksum, so it wasn't used."
        case .extract: "Couldn't unpack the search indexers."
        case .exited: "The search indexer service stopped unexpectedly."
        case .timeout: "The search indexer service didn't start in time."
        case .badReply: "The search indexer service gave an unexpected answer."
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
