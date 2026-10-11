import AppKit
import SwiftUI
import UserNotifications

enum SidebarItem: Hashable {
    case transfers(TransferFilter)
    case films, tv, music, other
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
    let search = SearchStore()
    let server: StreamServer
    let player: PlayerModel
    let audio: AudioPlayer

    var selection: SidebarItem? = .transfers(.all)
    var selectedTorrents: Set<String> = []
    var showInspector = false
    var showAddSheet = false
    var pendingRemoval: [Torrent] = []
    /// Set when something asks for the player window; observed by the scene that can open it.
    var playerRequest = 0

    private init() {
        torrents = TorrentStore(settings: settings)
        server = StreamServer(session: torrents.session)
        player = PlayerModel(server: server, torrents: torrents, library: library)
        audio = AudioPlayer(server: server, library: library)
        torrents.onFinished = { [weak self] torrent in self?.torrentFinished(torrent) }
    }

    func start() {
        server.start()
        torrents.start()
        if settings.notifyOnCompletion {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func shutdown() {
        player.stop()
        audio.stop()
        library.saveNow()
        torrents.shutdown()
    }

    // MARK: - Opening things

    func open(urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "magnet" {
                torrents.add(magnet: url.absoluteString)
            } else if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                torrents.add(fileURL: url)
            }
        }
        selection = .transfers(.all)
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

    func play(tracks: [MediaItem], startingAt index: Int) {
        player.stop()
        audio.play(tracks.filter(\.fileExists), startingAt: index)
    }

    // MARK: - Events

    private func torrentFinished(_ torrent: Torrent) {
        if settings.addToLibraryAutomatically {
            Task {
                let files = await torrents.files(for: torrent.id)
                library.importTorrent(name: torrent.name, savePath: torrent.savePath, files: files, hash: torrent.id)
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

    func addToLibrary(_ torrent: Torrent) {
        Task {
            let files = await torrents.files(for: torrent.id)
            library.importTorrent(name: torrent.name, savePath: torrent.savePath, files: files.filter(\.isComplete), hash: torrent.id)
        }
    }

    var dockBadge: String? {
        let active = torrents.torrents.filter { $0.phase == .downloading || $0.phase == .fetchingMetadata }.count
        return active > 0 ? String(active) : nil
    }
}
