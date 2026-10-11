import AppKit
import SwiftUI
import UserNotifications
import WidgetKit

enum SidebarItem: Hashable {
    case transfers(TransferFilter)
    case shelf
    case films, tv, music, other
    case tag(UUID)
    case search, sources
}

enum TransferFilter: String, CaseIterable, Hashable {
    case all, downloading, seeding, completed

    var title: String {
        switch self {
        case .all: "All Transfers"
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .completed: "Completed"
        }
    }

    var symbol: String {
        switch self {
        case .all: "arrow.up.arrow.down"
        case .downloading: "arrow.down.circle"
        case .seeding: "arrow.up.circle"
        case .completed: "checkmark.circle"
        }
    }

    func matches(_ torrent: Torrent) -> Bool {
        switch self {
        case .all: true
        case .downloading: !torrent.isComplete
        case .seeding: torrent.phase == .seeding
        case .completed: torrent.isComplete
        }
    }
}

/// Root object wiring the engine, library, search and players together.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings.shared
    let torrents: TorrentStore
    let library = LibraryStore()
    let tags = TagStore()
    let compression: CompressionService
    let search = SearchStore()
    let server: StreamServer
    let player: PlayerModel
    let audio: AudioPlayer

    var selection: SidebarItem? = .transfers(.all)
    /// The shelf's search box; items that don't match fade back.
    var shelfQuery = ""
    var selectedTorrents: Set<String> = []
    var showInspector = false
    var showAddSheet = false
    var pendingRemoval: [Torrent] = []
    /// Set when something asks for the player window; observed by the scene that can open it.
    var playerRequest = 0

    private init() {
        torrents = TorrentStore(settings: settings)
        compression = CompressionService(library: library)
        server = StreamServer(session: torrents.session)
        player = PlayerModel(server: server, torrents: torrents, library: library)
        audio = AudioPlayer(server: server, library: library)
        player.onFinished = { [weak self] id in self?.playNextEpisode(after: id) }
        torrents.onFinished = { [weak self] torrent in self?.torrentFinished(torrent) }
    }

    func start() {
        server.start()
        torrents.start()
        startWidgetUpdates()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.packStaleItems()
        }
        // Screenshots: `PIECE_DEMO_QUERY=…` opens Search with that query already run.
        if DemoTorrents.isEnabled, let query = ProcessInfo.processInfo.environment["PIECE_DEMO_QUERY"] {
            selection = .search
            search.query = query
            search.search()
        }
        // Get the built-in search indexers ready in the background so the first search is instant.
        if !DemoTorrents.isEnabled, search.providers.contains(where: { $0.id == JackettManager.providerID && $0.isEnabled }) {
            Task { try? await JackettManager.shared.ensureRunning() }
        }
        if settings.notifyOnCompletion, !DemoTorrents.isEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func shutdown() {
        player.stop()
        audio.stop()
        JackettManager.shared.stop()
        library.saveNow()
        tags.saveNow()
        torrents.shutdown()
        try? FileManager.default.removeItem(at: AppPaths.temporary)
    }

    // MARK: - Opening things

    /// `piece://` links, plus the old `swarmly://` and `ktorrent://` schemes so existing links keep working.
    private static func isAppLink(_ url: URL) -> Bool {
        ["piece", "swarmly", "ktorrent"].contains(url.scheme?.lowercased() ?? "")
    }

    func open(urls: [URL]) {
        for url in urls {
            if Self.isAppLink(url) {
                handleDeepLink(url)
                continue
            }
            if url.scheme?.lowercased() == "magnet" {
                torrents.add(magnet: url.absoluteString)
            } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                torrents.add(fileURL: url)
            }
        }
        if !urls.contains(where: Self.isAppLink) { selection = .transfers(.all) }
    }

    /// `piece://shelf?q=…`, `piece://show/films`, `piece://search?q=…`, `piece://play?hash=…`, `piece://stop`, `piece://inspect?hash=…`
    private func handleDeepLink(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch url.host?.lowercased() {
        case "show":
            switch url.lastPathComponent.lowercased() {
            case "shelf": selection = .shelf
            case "films": selection = .films
            case "tv": selection = .tv
            case "music": selection = .music
            case "other": selection = .other
            case "search": selection = .search
            case "sources": selection = .sources
            default: selection = .transfers(.all)
            }
        case "shelf":
            selection = .shelf
            shelfQuery = value("q") ?? ""
        case "search":
            selection = .search
            search.query = value("q") ?? ""
            search.search()
        case "play":
            if let hash = value("hash")?.lowercased(), let torrent = torrents.torrent(hash) {
                if value("muted") == "1" { player.player.isMuted = true }
                preview(torrent)
            }
        case "stop":
            player.stop()
            player.player.isMuted = false
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("player") == true }?.close()
        case "inspect":
            if let hash = value("hash")?.lowercased() {
                selection = .transfers(.all)
                selectedTorrents = [hash]
                showInspector = true
            }
        default:
            break
        }
    }

    func addFromPasteboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.lowercased().hasPrefix("magnet:") || text.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
        else { return false }
        Task { await torrents.add(link: text) }
        selection = .transfers(.all)
        return true
    }

    func chooseTorrentFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.init(filenameExtension: "torrent") ?? .data]
        panel.message = "Choose torrent files to add"
        guard panel.runModal() == .OK else { return }
        open(urls: panel.urls)
    }

    // MARK: - Playback

    func play(file: TorrentFile, in torrent: Torrent) {
        let absolute = torrents.absolutePath(of: file, in: torrent)
        let parsed = ReleaseNameParser.parse(file.name)
        let item = PlaybackItem(
            title: parsed.title.isEmpty ? file.name : parsed.title,
            detail: parsed.isEpisode ? String(format: "S%02dE%02d", parsed.season ?? 0, parsed.episode ?? 0) : nil,
            origin: .torrent(hash: torrent.id, fileIndex: file.index, relativePath: file.path, absolutePath: absolute, size: file.size))
        audio.stop()
        player.play(item)
        playerRequest += 1
    }

    /// Plays the biggest video (or first audio file) in a torrent: the "preview" button.
    func preview(_ torrent: Torrent) {
        Task {
            let files = await torrents.files(for: torrent.id)
            let playable = files.filter { $0.kind == .video }.max { $0.size < $1.size }
                ?? files.first { $0.kind == .audio }
            if let playable { play(file: playable, in: torrent) }
        }
    }

    func play(_ media: MediaItem, fromStart: Bool = false) {
        if media.isPacked {
            // Packed items have to come back first; play as soon as they're restored.
            compression.unpack([media]) { [weak self] in
                if let restored = self?.library.item(media.id), !restored.isPacked { self?.play(restored, fromStart: fromStart) }
            }
            return
        }
        guard media.fileExists else {
            torrents.lastError = "“\(media.title)” can't be found. It may have been moved or deleted."
            return
        }
        if media.kind == .track {
            audio.play([media])
            return
        }
        var item = PlaybackItem(title: media.kind == .episode ? (media.showTitle ?? media.title) : media.title,
                                detail: media.kind == .episode ? "\(media.episodeCode) · \(media.title)" : media.yearText,
                                origin: .file(media.url), libraryID: media.id)
        if fromStart { item.startPosition = 0.001 }
        audio.stop()
        player.play(item)
        playerRequest += 1
    }

    /// When an episode ends, carry straight on with the next one in the same show.
    private func playNextEpisode(after id: UUID) {
        guard let finished = library.item(id), finished.kind == .episode, let show = finished.showTitle?.lowercased() else { return }
        let episodes = library.items.filter { $0.kind == .episode && $0.showTitle?.lowercased() == show }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        guard let index = episodes.firstIndex(where: { $0.id == id }), index + 1 < episodes.count else { return }
        let next = episodes[index + 1]
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard player.item == nil || player.item?.libraryID == id else { return }
            play(next, fromStart: true)
        }
    }

    func play(tracks: [MediaItem], startingAt index: Int) {
        if tracks.contains(where: \.isPacked) {
            let ids = tracks.map(\.id)
            compression.unpack(tracks) { [weak self] in
                guard let self else { return }
                self.play(tracks: ids.compactMap(self.library.item), startingAt: index)
            }
            return
        }
        player.stop()
        audio.play(tracks.filter(\.fileExists), startingAt: index)
    }

    // MARK: - Events

    private func torrentFinished(_ torrent: Torrent) {
        if settings.addToLibraryAutomatically {
            Task {
                let files = await torrents.files(for: torrent.id)
                library.importTorrent(name: torrent.name, savePath: torrent.savePath, files: files, hash: torrent.id)
                if settings.compressOnComplete {
                    // Give the engine a moment to release the files before rewriting them.
                    try? await Task.sleep(for: .seconds(5))
                    compression.compress(library.items.filter { $0.torrentHash == torrent.id })
                }
            }
        }
        if settings.notifyOnCompletion {
            let content = UNMutableNotificationContent()
            content.title = "Download complete"
            content.body = torrent.name
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: torrent.id, content: content, trigger: nil))
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Packing deletes the original files, so anything still being shared has to stop first.
    func pack(_ items: [MediaItem]) {
        let hashes = Set(items.compactMap(\.torrentHash))
        for hash in hashes {
            if let torrent = torrents.torrent(hash) { torrents.remove(torrent, deleteFiles: false) }
        }
        compression.pack(items)
    }

    /// Items that were last opened (or added) longer ago than the "auto-pack" setting.
    func packStaleItems() {
        let days = settings.autoPackAfterDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let stale = library.items.filter { !$0.isPacked && $0.fileExists && ($0.lastPlayed ?? $0.dateAdded) < cutoff && $0.fileSize > 50_000_000
            && ($0.torrentHash.flatMap { torrents.torrent($0) } == nil) }
        if !stale.isEmpty { compression.pack(stale) }
    }

    func addToLibrary(_ torrent: Torrent) {
        Task {
            let files = await torrents.files(for: torrent.id)
            library.importTorrent(name: torrent.name, savePath: torrent.savePath, files: files.filter(\.isComplete), hash: torrent.id)
        }
    }
}

// MARK: - Widget

extension AppModel {
    /// Shares a summary with the Piece widget about every 15 seconds, only touching disk when something changed.
    func startWidgetUpdates() {
        guard !AppPaths.isTesting, !DemoTorrents.isEnabled, WidgetSnapshot.fileURL != nil else { return }
        Task { [weak self] in
            var last: WidgetSnapshot?
            while let self {
                var snapshot = self.makeWidgetSnapshot()
                snapshot.updated = last?.updated ?? snapshot.updated
                if snapshot != last {
                    snapshot.updated = Date()
                    snapshot.write()
                    WidgetCenter.shared.reloadAllTimelines()
                    last = snapshot
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func makeWidgetSnapshot() -> WidgetSnapshot {
        let active = torrents.torrents.filter { !$0.isComplete }
        return WidgetSnapshot(
            downloadRate: torrents.downloadRate, uploadRate: torrents.uploadRate, activeCount: active.count,
            transfers: active.prefix(4).map {
                .init(id: $0.id, name: $0.name, progress: $0.progress, status: $0.statusLine, isPaused: $0.phase == .paused)
            },
            recents: library.items.filter { $0.kind != .track }.sorted { $0.dateAdded > $1.dateAdded }.prefix(4).map {
                .init(id: $0.id.uuidString, title: $0.kind == .episode ? ($0.showTitle ?? $0.title) : $0.title,
                      subtitle: $0.kind == .episode ? $0.episodeCode : $0.yearText, kind: $0.kind.rawValue)
            },
            savedBytes: compression.totalSaved)
    }
}
