import Foundation

/// Saves disk space two ways:
///  1. **Compress** (automatic): rewrites a finished file with APFS transparent compression. It stays a normal
///     file in the same place — playable, seedable and visible in Finder — and just takes less room.
///  2. **Pack**: moves the file into a verified `.piecepack` archive and removes the original. Much smaller for
///     compressible things, but it has to be unpacked before it can be used.
@MainActor
@Observable
final class CompressionService {
    struct Job: Identifiable {
        let id = UUID()
        var title: String
        var progress: Double = 0
        var detail: String
    }

    private(set) var jobs: [Job] = []
    private(set) var lastError: String?
    var isBusy: Bool { !jobs.isEmpty }

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var cancelled: Set<UUID> = []
    @ObservationIgnored private var queue: [() async -> Void] = []
    @ObservationIgnored private var running = false

    init(library: LibraryStore) {
        self.library = library
    }

    static var packsFolder: URL { AppPaths.directory("Packs") }

    /// Total space saved by compressing and packing, for display.
    var totalSaved: Int64 { library.items.reduce(0) { $0 + ($1.savedBytes ?? 0) } }

    func cancel(_ job: Job) { cancelled.insert(job.id) }

    // MARK: - Compress (transparent)

    /// Which files are worth rewriting: big enough, and a quick sample actually shrinks.
    nonisolated static func isWorthCompressing(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize, size >= 1_000_000 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // A sample from the middle: headers are rarely representative.
        try? handle.seek(toOffset: UInt64(max(0, size / 2 - 2 * 1024 * 1024)))
        guard let sample = try? handle.read(upToCount: 4 * 1024 * 1024), !sample.isEmpty,
              let packed = try? (sample as NSData).compressed(using: .lzfse) as Data else { return false }
        return Double(packed.count) < Double(sample.count) * 0.97
    }

    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    /// Rewrites one file with transparent compression. Returns the bytes saved (0 if it wasn't worth it).
    nonisolated static func compressInPlace(_ url: URL) throws -> Int64 {
        guard isWorthCompressing(url) else { return 0 }
        let fm = FileManager.default
        let before = allocatedSize(url)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".piece-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: temp) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--hfsCompression", url.path, temp.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { return 0 }
        let sizes = try (url.resourceValues(forKeys: [.fileSizeKey]).fileSize, temp.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        guard sizes.0 == sizes.1 else { return 0 }
        let after = allocatedSize(temp)
        // Keep it only if it clearly helped.
        guard before > 0, Double(after) < Double(before) * 0.97 else { return 0 }
        _ = try fm.replaceItemAt(url, withItemAt: temp)
        return before - after
    }

    func compress(_ items: [MediaItem]) {
        for item in items where !item.isPacked && item.fileExists {
            enqueue(Job(title: item.title, detail: "Compressing…")) { [weak self] job in
                let url = item.url
                let saved = await Task.detached(priority: .utility) { try? Self.compressInPlace(url) }.value ?? 0
                self?.library.update(item.id) { $0.savedBytes = max($0.savedBytes ?? 0, saved) }
                _ = job
            }
        }
    }

    // MARK: - Pack / unpack

    func pack(_ items: [MediaItem]) {
        for item in items where !item.isPacked && item.fileExists {
            enqueue(Job(title: item.title, detail: "Packing…")) { [weak self] job in
                guard let self else { return }
                let destination = Self.packsFolder.appendingPathComponent("\(item.id.uuidString).piecepack")
                let source = item.url
                let id = job.id
                do {
                    let original = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? item.fileSize
                    try await Task.detached(priority: .utility) {
                        _ = try PackFormat.pack(files: [(source, source.lastPathComponent)], to: destination,
                                                progress: { fraction in Task { @MainActor in self.setProgress(fraction * 0.6, id: id) } },
                                                isCancelled: { DispatchQueue.main.sync { self.cancelled.contains(id) } })
                        // Check the pack by reading it all back before the original goes anywhere.
                        try PackFormat.unpack(destination, destination: nil,
                                              progress: { fraction in Task { @MainActor in self.setProgress(0.6 + fraction * 0.4, id: id) } },
                                              isCancelled: { DispatchQueue.main.sync { self.cancelled.contains(id) } })
                    }.value
                    let packedBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    try FileManager.default.removeItem(at: source)
                    self.library.update(item.id) {
                        $0.packedFile = destination.lastPathComponent
                        $0.packedBytes = packedBytes
                        $0.savedBytes = max(0, original - packedBytes)
                        $0.fileSize = original
                    }
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    if case PackError.cancelled = error {} else {
                        self.lastError = "Couldn't pack “\(item.title)”: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Restores packed items to where they were. Calls `completion` once all are done.
    func unpack(_ items: [MediaItem], completion: (@MainActor () -> Void)? = nil) {
        let packed = items.filter(\.isPacked)
        guard !packed.isEmpty else { completion?(); return }
        for (index, item) in packed.enumerated() {
            enqueue(Job(title: item.title, detail: "Unpacking…")) { [weak self] job in
                guard let self, let name = item.packedFile else { return }
                let pack = Self.packsFolder.appendingPathComponent(name)
                let destination = item.url
                let id = job.id
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try PackFormat.unpack(pack, destination: { _ in destination },
                                              progress: { fraction in Task { @MainActor in self.setProgress(fraction, id: id) } },
                                              isCancelled: { DispatchQueue.main.sync { self.cancelled.contains(id) } })
                    }.value
                    try? FileManager.default.removeItem(at: pack)
                    self.library.update(item.id) {
                        $0.packedFile = nil
                        $0.packedBytes = nil
                        $0.savedBytes = nil
                    }
                } catch {
                    self.lastError = "Couldn't unpack “\(item.title)”: \(error.localizedDescription)"
                }
                if index == packed.count - 1 { completion?() }
            }
        }
    }

    // MARK: - Queue

    private func setProgress(_ value: Double, id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].progress = value }
    }

    private func enqueue(_ job: Job, _ work: @escaping (Job) async -> Void) {
        jobs.append(job)
        queue.append { [weak self] in
            await work(job)
            self?.jobs.removeAll { $0.id == job.id }
            self?.cancelled.remove(job.id)
        }
        guard !running else { return }
        running = true
        Task {
            while !queue.isEmpty { await queue.removeFirst()() }
            running = false
        }
    }
}
