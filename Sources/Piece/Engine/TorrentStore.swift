import AppKit
import Foundation

/// Owns the libtorrent session and publishes torrent state to the UI.
@MainActor
@Observable
final class TorrentStore {
    private(set) var torrents: [Torrent] = []
    private(set) var downloadRate = 0
    private(set) var uploadRate = 0
    private(set) var speedHistory: [SpeedSample] = []
    var lastError: String?

    /// Called on the main actor when a torrent finishes downloading.
    var onFinished: ((Torrent) -> Void)?

    @ObservationIgnored let session: KTSession
    /// Holds transfers on battery power or a metered connection, when the user asked for it.
    let policy: TransferPolicy
    @ObservationIgnored private let queue = DispatchQueue(label: "Piece.engine", qos: .userInitiated)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var byID: [String: Torrent] = [:]
    @ObservationIgnored private var isShutDown = false
    /// Transfers seen downloading (or fetching metadata) during this run. libtorrent also reports "finished"
    /// for completed torrents it restores at launch; only these ones have really just finished.
    @ObservationIgnored private var seenIncomplete: Set<String> = []

    init(settings: AppSettings) {
        let state = AppPaths.directory("State").path
        session = KTSession(stateDirectory: state, settings: settings.sessionSettings)
        policy = TransferPolicy(settings: settings)
        // Restored transfers keep whatever trackers they were saved with; the rules were applied
        // when they were added, or when the rules last changed.
        session.setMergeTrackers(settings.trackers(.merge), filterTrackers: settings.trackers(.filter), applyToExisting: false)
    }

    func start() {
        if DemoTorrents.isEnabled { loadDemo(); return }
        let session = session
        policy.onChange = { [weak self] active, exempt in self?.applyHold(active, exempt: exempt) }
        // Decides the hold before anything is restored, so held transfers never start at launch.
        policy.start()
        queue.async { [weak self] in
            session.restoreTorrents()
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func loadDemo() {
        torrents = DemoTorrents.makeTorrents()
        for torrent in torrents { byID[torrent.id] = torrent }
        downloadRate = torrents.reduce(0) { $0 + $1.downloadRate }
        uploadRate = torrents.reduce(0) { $0 + $1.uploadRate }
        speedHistory = (0..<120).map { i in
            let wave = 0.8 + 0.2 * sin(Double(i) / 8)
            return SpeedSample(down: Int(Double(downloadRate) * wave), up: Int(Double(uploadRate) * wave))
        }
    }

    func applySettings(_ settings: AppSettings) {
        let s = settings.sessionSettings
        let session = session
        queue.async { session.apply(s) }
    }

    /// Pushes the app-wide tracker lists to the engine and applies them to every current transfer.
    func applyTrackerRules(_ settings: AppSettings) {
        let merge = settings.trackers(.merge), filter = settings.trackers(.filter)
        let session = session
        queue.async { session.setMergeTrackers(merge, filterTrackers: filter, applyToExisting: true) }
    }

    func torrent(_ id: String) -> Torrent? { byID[id] }

    private func applyHold(_ active: Bool, exempt: Set<String>) {
        guard !isShutDown else { return }
        let session = session
        let hashes = Array(exempt)
        queue.async { session.setHoldActive(active, exempt: hashes) }
        refresh()
    }

    // MARK: - Polling

    private func refresh() {
        guard !isShutDown else { return }
        tick += 1
        let saveNow = tick % 30 == 0
        let session = session
        queue.async { [weak self] in
            let statuses = session.statuses()
            let events = session.pollEvents()
            if saveNow { session.saveResumeData() }
            Task { @MainActor in self?.apply(statuses: statuses, events: events) }
        }
    }

    private func apply(statuses: [KTTorrentStatus], events: [KTEvent]) {
        var seen = Set<String>()
        var down = 0, up = 0
        var added = false
        for status in statuses {
            seen.insert(status.infoHash)
            let torrent: Torrent
            if let existing = byID[status.infoHash] {
                torrent = existing
            } else {
                torrent = Torrent(id: status.infoHash, name: status.name)
                byID[status.infoHash] = torrent
                torrents.append(torrent)
                added = true
            }
            torrent.apply(status)
            if status.state == .downloading || status.state == .fetchingMetadata { seenIncomplete.insert(status.infoHash) }
            if status.held, torrent.heldStatus != policy.heldStatus { torrent.heldStatus = policy.heldStatus }
            down += Int(status.downloadRate)
            up += Int(status.uploadRate)
        }
        if seen.count != torrents.count {
            torrents.removeAll { !seen.contains($0.id) }
            byID = byID.filter { seen.contains($0.key) }
            seenIncomplete.formIntersection(seen)
        }
        if added { torrents.sort { $0.dateAdded > $1.dateAdded } }
        if downloadRate != down { downloadRate = down }
        if uploadRate != up { uploadRate = up }
        speedHistory.append(SpeedSample(down: down, up: up))
        if speedHistory.count > 120 { speedHistory.removeFirst(speedHistory.count - 120) }

        for event in events {
            guard let torrent = byID[event.infoHash] else { continue }
            switch event.type {
            case .finished:
                // libtorrent also reports "finished" when a completed torrent is restored at launch.
                if seenIncomplete.remove(event.infoHash) != nil || Date().timeIntervalSince(torrent.dateAdded) < 60 {
                    onFinished?(torrent)
                }
            case .error:
                torrent.errorMessage = event.message
            default:
                break
            }
        }
    }

    // MARK: - Adding

    @discardableResult
    func add(magnet: String, savePath: String? = nil) -> String? {
        let path = savePath ?? AppSettings.shared.downloadFolder
        do {
            let hash = try session.addMagnet(magnet, savePath: path)
            refresh()
            return hash
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func add(torrentData: Data, savePath: String? = nil, reportErrors: Bool = true) -> String? {
        let path = savePath ?? AppSettings.shared.downloadFolder
        do {
            let hash = try session.addTorrentData(torrentData, savePath: path)
            refresh()
            return hash
        } catch {
            if reportErrors { lastError = error.localizedDescription }
            return nil
        }
    }

    @discardableResult
    func add(fileURL: URL, savePath: String? = nil) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else {
            lastError = "Couldn't read \(fileURL.lastPathComponent)."
            return nil
        }
        return add(torrentData: data, savePath: savePath)
    }

    /// Accepts a magnet link, an http(s) link to a .torrent file, or a bare info-hash.
    func add(link: String, savePath: String? = nil) async -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("magnet:") { return add(magnet: text, savePath: savePath) }
        if text.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil {
            return add(magnet: "magnet:?xt=urn:btih:\(text)", savePath: savePath)
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme.hasPrefix("http") else {
            lastError = "That doesn't look like a magnet link or torrent URL."
            return nil
        }
        do {
            var request = URLRequest(url: url)
            request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
            let redirectGuard = MagnetRedirectGuard()
            let (data, _) = try await URLSession.shared.data(for: request, delegate: redirectGuard)
            if let magnet = redirectGuard.magnet { return add(magnet: magnet, savePath: savePath) }
            if let text = String(data: data.prefix(4096), encoding: .utf8),
               let magnet = text.firstMatch(of: /magnet:\?xt=urn:bt[a-z0-9]+:[^"'<\s]+/) {
                return add(magnet: String(magnet.0), savePath: savePath)
            }
            return add(torrentData: data, savePath: savePath)
        } catch {
            lastError = "Couldn't download the torrent: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Control

    func pause(_ torrent: Torrent) {
        policy.forget(torrent.id)
        let session = session, id = torrent.id
        // On the engine queue like resume, so the two always run in the order they were asked for.
        queue.async { session.pauseTorrent(id) }
        refresh()
    }

    /// While transfers are held, resuming one lets it run anyway until the conditions change.
    func resume(_ torrent: Torrent) {
        if policy.isHolding { policy.resumeAnyway(torrent.id) }
        let session = session, id = torrent.id
        // After the hold update queued above, so the hold doesn't pause it again.
        queue.async { session.resumeTorrent(id) }
        refresh()
    }

    /// Starts a transfer that is waiting in the queue, for playback that can't wait for its turn.
    func forceStart(_ torrent: Torrent) {
        if policy.isHolding { policy.resumeAnyway(torrent.id) }
        let session = session, id = torrent.id
        queue.async { session.forceStartTorrent(id) }
        refresh()
    }

    func toggle(_ torrent: Torrent) {
        if torrent.canResume {
            resume(torrent)
        } else {
            pause(torrent)
        }
    }

    func remove(_ torrent: Torrent, deleteFiles: Bool) {
        session.removeTorrent(torrent.id, deleteFiles: deleteFiles)
        torrents.removeAll { $0.id == torrent.id }
        byID[torrent.id] = nil
    }

    func recheck(_ torrent: Torrent) { session.recheck(torrent.id) }
    func reannounce(_ torrent: Torrent) { session.reannounceTorrent(torrent.id) }

    func pauseAll() {
        policy.endOverride()
        let session = session, ids = torrents.map(\.id)
        queue.async { ids.forEach(session.pauseTorrent) }
        refresh()
    }

    /// While transfers are held this is "Resume Anyway" for everything.
    func resumeAll() {
        if policy.isHolding { policy.overrideHold() }
        let session = session, ids = torrents.map(\.id)
        queue.async { ids.forEach(session.resumeTorrent) }
        refresh()
    }

    // MARK: - Details

    func files(for id: String) async -> [TorrentFile] {
        let session = session
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: session.files(forTorrent: id).map(TorrentFile.init))
            }
        }
    }

    func peers(for id: String) async -> [TorrentPeer] {
        let session = session
        return await withCheckedContinuation { continuation in
            queue.async {
                let peers = session.peers(forTorrent: id).map {
                    TorrentPeer(address: $0.address, client: $0.client, progress: Double($0.progress),
                                downloadRate: Int($0.downloadRate), uploadRate: Int($0.uploadRate), isSeed: $0.isSeed)
                }
                continuation.resume(returning: peers)
            }
        }
    }

    func trackers(for id: String) async -> [TorrentTracker] {
        let session = session
        return await withCheckedContinuation { continuation in
            queue.async {
                let trackers = session.trackers(forTorrent: id).map {
                    TorrentTracker(url: $0.url, message: $0.message, tier: Int($0.tier), seeds: Int($0.seeds),
                                   leechers: Int($0.leechers), working: $0.working, updating: $0.updating)
                }
                continuation.resume(returning: trackers)
            }
        }
    }

    /// Returns false when the transfer already has that tracker.
    func addTracker(_ url: String, to id: String) async -> Bool {
        let session = session
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: session.addTracker(url, toTorrent: id)) }
        }
    }

    func removeTracker(_ url: String, from id: String) async {
        let session = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                session.removeTracker(url, fromTorrent: id)
                continuation.resume()
            }
        }
    }

    func pieceMap(for id: String) async -> [UInt8] {
        let session = session
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: [UInt8](session.pieceMap(forTorrent: id))) }
        }
    }

    func setWanted(_ wanted: Bool, file: Int, in id: String) {
        session.setPriority(wanted ? 4 : 0, forFile: Int32(file), inTorrent: id)
    }

    func magnetLink(for torrent: Torrent) -> String? { session.magnetLink(forTorrent: torrent.id) }

    func absolutePath(of file: TorrentFile, in torrent: Torrent) -> String {
        (torrent.savePath as NSString).appendingPathComponent(file.path)
    }

    /// The file as it is on disk right now: its final path, or the `.part` one while it is still downloading.
    func onDiskPath(of file: TorrentFile, in torrent: Torrent) -> String {
        let final = absolutePath(of: file, in: torrent)
        let current = (torrent.savePath as NSString).appendingPathComponent(file.diskPath)
        return FileManager.default.fileExists(atPath: current) ? current : PartFile.resolve(final)
    }

    /// Top-level file or folder the torrent was saved as.
    func contentURL(of torrent: Torrent) -> URL {
        URL(fileURLWithPath: torrent.savePath).appendingPathComponent(torrent.name)
    }

    func revealInFinder(_ torrent: Torrent) {
        let url = URL(fileURLWithPath: PartFile.resolve(contentURL(of: torrent).path))
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: torrent.savePath))
        }
    }

    // MARK: - Shutdown

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        timer?.invalidate()
        let session = session
        queue.sync { session.shutdown() }
    }
}

enum HTTP {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}


/// Indexers such as Jackett answer a download request with a redirect to a `magnet:` URL, which
/// URLSession can't follow ("unsupported URL"). This stops at that redirect and keeps the magnet.
private final class MagnetRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var found: String?
    var magnet: String? { lock.lock(); defer { lock.unlock() }; return found }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, url.scheme?.lowercased() == "magnet" {
            lock.lock(); found = url.absoluteString; lock.unlock()
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}
