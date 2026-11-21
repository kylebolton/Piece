import Foundation

/// IP blocklists: downloading or importing a list, unpacking it with the tools macOS ships with,
/// and handing the plain-text result to the engine, which refuses peers in the listed ranges.
enum Blocklist {
    /// How old the installed list can get before it's refreshed at launch.
    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    enum Packing: Equatable {
        case plain, gzip, xz, bzip2, zip, unsupported(String)
    }

    enum BlocklistError: LocalizedError {
        case download(Int)
        case unpack(String)
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .download(let status): "The server answered with status \(status)."
            case .unpack(let reason): "The list couldn't be unpacked: \(reason)"
            case .unreadable: "The list couldn't be read."
            case .empty: "No IP ranges were found in that list."
            }
        }
    }

    static var directory: URL { AppPaths.directory("Blocklist") }
    /// The installed list, always unpacked plain text.
    static var installedFile: URL { directory.appendingPathComponent("blocklist.txt") }

    /// Identifies the packing from the file's first bytes, so a web address needs no file extension.
    static func packing(of head: Data) -> Packing {
        let b = [UInt8](head.prefix(6))
        if b.starts(with: [0x1F, 0x8B]) { return .gzip }
        if b.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if b.starts(with: [0x42, 0x5A, 0x68]) { return .bzip2 }
        if b.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if b.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) { return .unsupported("zstd") }
        if b.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) { return .unsupported("7-Zip") }
        return .plain
    }

    /// Writes the unpacked contents of `input` to `output`. Plain files are copied as they are.
    /// gzip, bzip2 and zip use the tools in /usr/bin; macOS has no xz command, but its
    /// `compression_tool` reads the .xz format.
    static func unpack(_ input: URL, to output: URL) async throws {
        let head = (try? FileHandle(forReadingFrom: input)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8)
        } ?? Data()
        let fm = FileManager.default
        try? fm.removeItem(at: output)
        switch packing(of: head) {
        case .plain:
            try fm.copyItem(at: input, to: output)
        case .gzip:
            try await run("/usr/bin/gzip", ["-dc"], stdin: input, stdout: output, acceptedStatuses: [0, 2])
        case .bzip2:
            try await run("/usr/bin/bzip2", ["-dc"], stdin: input, stdout: output)
        case .xz:
            try await run("/usr/bin/compression_tool", ["-decode", "-a", "lzma", "-i", input.path, "-o", output.path])
        case .zip:
            try await run("/usr/bin/unzip", ["-p", input.path], stdout: output)
        case .unsupported(let name):
            throw BlocklistError.unpack("\(name) archives aren't supported. Use gzip, xz, bzip2 or zip.")
        }
    }

    /// Runs `tool`, sending its output to `stdout` when given (otherwise the tool writes the file itself).
    private static func run(_ tool: String, _ arguments: [String], stdin: URL? = nil, stdout: URL? = nil,
                            acceptedStatuses: Set<Int32> = [0]) async throws {
        var out: FileHandle?
        if let stdout {
            guard FileManager.default.createFile(atPath: stdout.path, contents: nil) else { throw BlocklistError.unreadable }
            out = try FileHandle(forWritingTo: stdout)
        }
        let input = try stdin.map { try FileHandle(forReadingFrom: $0) }
        defer { try? out?.close(); try? input?.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = out ?? FileHandle.nullDevice
        process.standardInput = input ?? FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard acceptedStatuses.contains(status) else {
            let text = (try? errors.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BlocklistError.unpack(reason.isEmpty ? "\((tool as NSString).lastPathComponent) failed (\(status))." : reason)
        }
    }

    /// Downloads `url` into the blocklist folder and returns where it landed.
    static func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw BlocklistError.download(http.statusCode)
        }
        // URLSession deletes its file once it's done with it, so keep a copy of our own.
        let kept = directory.appendingPathComponent("download")
        try? FileManager.default.removeItem(at: kept)
        try FileManager.default.moveItem(at: temporary, to: kept)
        return kept
    }
}

/// Keeps the installed blocklist and the engine's address filter in step with the settings.
@MainActor
@Observable
final class BlocklistManager {
    private(set) var isWorking = false
    /// The outcome of the last action, shown under the controls.
    private(set) var message: String?
    private(set) var messageIsError = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let session: KTSession

    init(settings: AppSettings, session: KTSession) {
        self.settings = settings
        self.session = session
    }

    /// Loads the installed list into the engine and refreshes it when it has gone stale.
    func start() {
        guard settings.blocklistEnabled, !AppPaths.isTesting, !DemoTorrents.isEnabled else { return }
        Task {
            if FileManager.default.fileExists(atPath: Blocklist.installedFile.path) {
                _ = await load(Blocklist.installedFile)
            }
            let stale = settings.blocklistUpdated.map { Date().timeIntervalSince($0) > Blocklist.refreshInterval } ?? true
            if settings.blocklistAutoUpdate, stale, URL(string: settings.blocklistURL) != nil, !settings.blocklistURL.isEmpty {
                await update()
            }
        }
    }

    /// Called when the switch is flipped.
    func enabledChanged() {
        if !settings.blocklistEnabled {
            session.clearBlocklist()
            message = nil
            return
        }
        Task {
            if FileManager.default.fileExists(atPath: Blocklist.installedFile.path) {
                _ = await load(Blocklist.installedFile)
            } else if !settings.blocklistURL.trimmingCharacters(in: .whitespaces).isEmpty {
                await update()
            } else {
                report("Enter a list address or import a file to start blocking.", isError: false)
            }
        }
    }

    /// Downloads the list from the saved address and installs it.
    func update() async {
        let text = settings.blocklistURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            report("Enter an http or https address.", isError: true)
            return
        }
        await perform(status: "Downloading…") {
            let file = try await Blocklist.download(url)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await self.install(file, source: text)
        }
    }

    /// Installs a list from a file on disk, packed or not.
    func importFile(_ url: URL) async {
        await perform(status: "Reading…") {
            // Copy first: the chosen file may be on a volume that goes away mid-way.
            let copy = Blocklist.directory.appendingPathComponent("import")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)
            defer { try? FileManager.default.removeItem(at: copy) }
            return try await self.install(copy, source: url.lastPathComponent)
        }
    }

    /// Forgets the installed list and lets every peer connect again.
    func remove() {
        session.clearBlocklist()
        try? FileManager.default.removeItem(at: Blocklist.installedFile)
        settings.blocklistEnabled = false
        settings.blocklistRuleCount = 0
        settings.blocklistSource = ""
        settings.blocklistUpdated = nil
        message = nil
    }

    // MARK: -

    private func perform(status: String, _ work: @escaping () async throws -> Int) async {
        guard !isWorking else { return }
        isWorking = true
        message = status
        messageIsError = false
        defer { isWorking = false }
        do {
            let rules = try await work()
            report("Blocking \(rules.formatted()) address ranges.", isError: false)
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    /// Unpacks `file`, checks it with the engine, and only then replaces the installed list.
    private func install(_ file: URL, source: String) async throws -> Int {
        let staged = Blocklist.directory.appendingPathComponent("incoming.txt")
        defer { try? FileManager.default.removeItem(at: staged) }
        try await Blocklist.unpack(file, to: staged)
        let rules = await load(staged)
        guard rules > 0 else { throw rules == 0 ? Blocklist.BlocklistError.empty : Blocklist.BlocklistError.unreadable }
        try? FileManager.default.removeItem(at: Blocklist.installedFile)
        try FileManager.default.moveItem(at: staged, to: Blocklist.installedFile)
        settings.blocklistEnabled = true
        settings.blocklistSource = source
        settings.blocklistRuleCount = rules
        settings.blocklistUpdated = Date()
        return rules
    }

    /// Parsing a few hundred thousand lines takes a moment, so it stays off the main thread.
    private func load(_ file: URL) async -> Int {
        let session = session
        let path = file.path
        let rules = await Task.detached(priority: .utility) { session.loadBlocklist(atPath: path) }.value
        if rules > 0, file == Blocklist.installedFile { settings.blocklistRuleCount = rules }
        return rules
    }

    private func report(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }
}
