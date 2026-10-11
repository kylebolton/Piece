import AppKit
import Foundation

/// The media library: a JSON-backed list of films, episodes, tracks and other downloads.
@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [MediaItem] = []
    private(set) var activity: String?

    @ObservationIgnored private let fileURL = AppPaths.support.appendingPathComponent("library.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var enrichQueue: [UUID] = []
    @ObservationIgnored private var isEnriching = false
    @ObservationIgnored private var showCache: [String: MetadataMatch] = [:]
    @ObservationIgnored private var albumArtCache: [String: String] = [:]

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
            items = decoded
        }
    }

    // MARK: - Views of the data

    var films: [MediaItem] { items.filter { $0.kind == .film } }
    var tracks: [MediaItem] { items.filter { $0.kind == .track } }
    var others: [MediaItem] { items.filter { $0.kind == .other } }

    var shows: [Show] {
        Dictionary(grouping: items.filter { $0.kind == .episode }) { ($0.showTitle ?? $0.title).lowercased() }
            .values.map { Show(title: $0.first?.showTitle ?? $0.first?.title ?? "", episodes: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var albums: [Album] {
        Dictionary(grouping: tracks) { "\(($0.albumArtist ?? $0.artist ?? "").lowercased())|\(($0.album ?? "").lowercased())" }
            .values.map { tracks in
                Album(title: tracks.first?.album ?? "Unknown Album",
                      artist: tracks.first?.albumArtist ?? tracks.first?.artist ?? "Unknown Artist",
                      tracks: tracks.sorted { $0.sortTrack < $1.sortTrack })
            }
            .sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    func count(of kind: MediaKind) -> Int { items.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }
    func item(_ id: UUID) -> MediaItem? { items.first { $0.id == id } }

    // MARK: - Mutation

    func update(_ id: UUID, _ change: (inout MediaItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>, moveToTrash: Bool) {
        if moveToTrash {
            for item in items where ids.contains(item.id) {
                try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            }
        }
        items.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func removeMissing() {
        items.removeAll { !$0.fileExists }
        scheduleSave()
    }

    func setWatched(_ watched: Bool, ids: Set<UUID>) {
        for id in ids {
            update(id) {
                $0.isWatched = watched
                if !watched { $0.playPosition = 0 }
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Importing

    /// Adds a finished torrent's files to the library.
    func importTorrent(name: String, savePath: String, files: [TorrentFile], hash: String) {
        let paths = files.filter(\.isWanted).map { (savePath as NSString).appendingPathComponent($0.path) }
        let added = importFiles(paths, torrentHash: hash)
        if added == 0, !items.contains(where: { $0.torrentHash == hash }) {
            // Nothing playable: keep one entry for the whole download.
            let root = (savePath as NSString).appendingPathComponent(name)
            var item = MediaItem(kind: .other, path: root, title: name)
            item.fileSize = files.reduce(0) { $0 + $1.size }
            item.torrentHash = hash
            items.append(item)
            scheduleSave()
        }
    }

    func importFolder(_ folder: URL) {
        activity = "Scanning \(folder.lastPathComponent)…"
        Task {
            let paths = await Task.detached { () -> [String] in
                var found: [String] = []
                let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let url = enumerator?.nextObject() as? URL {
                    if FileKind(path: url.path).isPlayable { found.append(url.path) }
                }
                return found
            }.value
            importFiles(paths, torrentHash: nil)
            if !isEnriching { activity = nil }
        }
    }

    @discardableResult
    func importFiles(_ paths: [String], torrentHash: String?) -> Int {
        let existing = Set(items.map(\.path))
        var added: [MediaItem] = []
        for path in paths where !existing.contains(path) {
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
            guard var item = Self.classify(path: path, size: size) else { continue }
            item.torrentHash = torrentHash
            added.append(item)
        }
        guard !added.isEmpty else { return 0 }
        items.append(contentsOf: added)
        scheduleSave()
        enrichQueue.append(contentsOf: added.map(\.id))
        runEnrichment()
        return added.count
    }

    /// Decides what a media file is from its name and location alone.
    nonisolated static func classify(path: String, size: Int64) -> MediaItem? {
        let filename = (path as NSString).lastPathComponent
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        switch FileKind(path: path) {
        case .video:
            let lower = filename.lowercased()
            let isExtra = lower.contains("sample") || lower.contains("trailer") || folder.lowercased() == "sample"
            if isExtra, size < 200 * 1024 * 1024 { return nil }

            let fromFile = ReleaseNameParser.parse(filename)
            let fromFolder = ReleaseNameParser.parse(folder)
            let folderLooksLikeRelease = fromFolder.year != nil || fromFolder.resolution != nil || fromFolder.isEpisode

            if fromFile.isEpisode || (fromFolder.season != nil && Self.leadingNumber(filename) != nil) {
                var item = MediaItem(kind: .episode, path: path, title: "")
                item.season = fromFile.season ?? fromFolder.season ?? 1
                item.episode = fromFile.episode ?? Self.leadingNumber(filename)
                var show = fromFile.isEpisode ? fromFile.title : ""
                // "S01E02.mkv" inside "Show Name Season 1": the folder carries the title.
                if show.count < 2 || show.lowercased().hasPrefix("episode") {
                    show = folderLooksLikeRelease ? fromFolder.title : folder
                }
                item.showTitle = show
                item.title = "Episode \(item.episode ?? 0)"
                item.year = fromFile.year
                item.resolution = fromFile.resolution ?? fromFolder.resolution
                item.fileSize = size
                return item
            }

            var item = MediaItem(kind: .film, path: path, title: fromFile.title)
            item.year = fromFile.year
            if fromFile.year == nil, fromFolder.year != nil {
                item.title = fromFolder.title
                item.year = fromFolder.year
            }
            item.resolution = fromFile.resolution ?? (folderLooksLikeRelease ? fromFolder.resolution : nil)
            item.fileSize = size
            return item

        case .audio:
            var title = (filename as NSString).deletingPathExtension
            var item = MediaItem(kind: .track, path: path, title: title)
            // "03 - Song Name" / "03. Song Name"
            if let match = title.firstMatch(of: /^(\d{1,3})[\s._-]+(.+)$/) {
                item.trackNumber = Int(match.1)
                title = String(match.2)
                item.title = title
            }
            item.album = folder
            item.fileSize = size
            return item

        default:
            return nil
        }
    }

    nonisolated private static func leadingNumber(_ filename: String) -> Int? {
        filename.firstMatch(of: /^(\d{1,3})(?:\D|$)/).flatMap { Int($0.1) }
    }

    // MARK: - Metadata

    private func runEnrichment() {
        guard !isEnriching else { return }
        isEnriching = true
        Task {
            while !enrichQueue.isEmpty {
                let id = enrichQueue.removeFirst()
                guard let item = item(id) else { continue }
                activity = "Getting info for \(item.kind == .episode ? (item.showTitle ?? item.title) : item.title)…"
                await enrich(item)
            }
            isEnriching = false
            activity = nil
        }
    }

    private func enrich(_ item: MediaItem) async {
        let probe = await MediaProbe.probe(item.path)
        if let probe {
            update(item.id) {
                if probe.duration > 0 { $0.duration = probe.duration }
                if $0.resolution == nil, let height = probe.video?.height, let width = probe.video?.width {
                    $0.resolution = Self.resolutionLabel(width: width, height: height)
                }
            }
        }
        switch item.kind {
        case .film:
            if let match = await MetadataService.film(title: item.title, year: item.year) {
                await apply(match, to: item.id)
            }
        case .episode:
            await enrichEpisode(item)
        case .track:
            await enrichTrack(item, probe: probe)
        case .other:
            break
        }
    }

    nonisolated static func resolutionLabel(width: Int, height: Int) -> String {
        if width >= 3200 || height >= 1800 { return "2160p" }
        if width >= 1800 || height >= 1000 { return "1080p" }
        if width >= 1200 || height >= 700 { return "720p" }
        return "\(height)p"
    }

    private func enrichEpisode(_ item: MediaItem) async {
        let showTitle = item.showTitle ?? item.title
        let key = showTitle.lowercased()
        var match = showCache[key]
        if match == nil {
            match = await MetadataService.show(title: showTitle)
            showCache[key] = match
        }
        guard let match else { return }
        let poster = await artwork(match.posterURL)
        let backdrop = await artwork(match.backdropURL)
        var episodeInfo: (title: String?, overview: String?) = (nil, nil)
        if let showID = match.tmdbID, let season = item.season, let episode = item.episode {
            episodeInfo = await MetadataService.episode(showID: showID, season: season, episode: episode)
        }
        update(item.id) {
            $0.showTitle = match.title
            $0.tmdbID = match.tmdbID
            $0.genres = match.genres
            $0.rating = match.rating
            $0.artworkFile = poster ?? $0.artworkFile
            $0.backdropFile = backdrop ?? $0.backdropFile
            $0.overview = episodeInfo.overview.flatMap { $0.isEmpty ? nil : $0 } ?? match.overview
            if let title = episodeInfo.title, !title.isEmpty { $0.title = title }
            $0.isMatched = true
        }
    }

    private func enrichTrack(_ item: MediaItem, probe: MediaProbe?) async {
        let tags = probe?.tags ?? [:]
        func tag(_ names: String...) -> String? {
            for name in names { if let value = tags[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return value } }
            return nil
        }
        update(item.id) {
            if let title = tag("title") { $0.title = title }
            if let artist = tag("artist") { $0.artist = artist }
            if let album = tag("album") { $0.album = album }
            if let albumArtist = tag("album_artist", "albumartist") { $0.albumArtist = albumArtist }
            if let track = tag("track", "tracknumber") { $0.trackNumber = Int(track.split(separator: "/").first ?? "") ?? $0.trackNumber }
            if let disc = tag("disc", "discnumber") { $0.discNumber = Int(disc.split(separator: "/").first ?? "") }
            if let date = tag("date", "year", "originaldate") { $0.year = Int(date.prefix(4)) }
            if let genre = tag("genre") { $0.genres = [genre] }
            $0.isMatched = true
        }
        guard let current = self.item(item.id) else { return }
        let albumKey = "\((current.albumArtist ?? current.artist ?? "").lowercased())|\((current.album ?? "").lowercased())"
        if let cached = albumArtCache[albumKey] {
            update(item.id) { $0.artworkFile = cached }
            return
        }
        var file: String?
        if probe?.streams.contains(where: { $0.kind == .video }) == true {
            file = await Self.extractEmbeddedArtwork(from: item.path)
        }
        if file == nil, let album = current.album, !album.isEmpty,
           let match = await MetadataService.album(artist: current.albumArtist ?? current.artist ?? "", album: album) {
            file = await artwork(match.posterURL)
            if current.year == nil, let year = match.year { update(item.id) { $0.year = year } }
            if current.genres.isEmpty, !match.genres.isEmpty { update(item.id) { $0.genres = match.genres } }
        }
        if let file {
            albumArtCache[albumKey] = file
            update(item.id) { $0.artworkFile = file }
        }
    }

    nonisolated private static func extractEmbeddedArtwork(from path: String) async -> String? {
        guard let ffmpeg = AppPaths.helper("ffmpeg") else { return nil }
        let args = ["-v", "quiet", "-i", path, "-an", "-map", "0:v:0", "-frames:v", "1", "-f", "image2pipe", "-c:v", "mjpeg", "-"]
        guard let output = await ProcessRunner.run(ffmpeg, args, timeout: 30), output.status == 0,
              output.stdout.count > 500 else { return nil }
        return MetadataService.saveArtwork(output.stdout)
    }

    private func artwork(_ url: URL?) async -> String? {
        guard let url else { return nil }
        return await MetadataService.downloadArtwork(from: url)
    }

    /// Applies a chosen film match (also used by "Fix Match").
    func apply(_ match: MetadataMatch, to id: UUID) async {
        let poster = await artwork(match.posterURL)
        let backdrop = await artwork(match.backdropURL)
        update(id) {
            $0.title = match.title
            $0.year = match.year ?? $0.year
            $0.overview = match.overview
            $0.genres = match.genres
            $0.rating = match.rating
            $0.tmdbID = match.tmdbID
            $0.artworkFile = poster ?? $0.artworkFile
            $0.backdropFile = backdrop ?? $0.backdropFile
            $0.isMatched = true
        }
    }

    /// Re-points every episode of a show at a different match.
    func apply(_ match: MetadataMatch, toShow show: Show) async {
        showCache[match.title.lowercased()] = match
        for episode in show.episodes {
            update(episode.id) { $0.showTitle = match.title }
            if let updated = item(episode.id) { await enrichEpisode(updated) }
        }
    }

    func refreshMetadata(for ids: [UUID]) {
        enrichQueue.append(contentsOf: ids)
        runEnrichment()
    }

    /// Switches an item between Films and TV when the automatic guess was wrong.
    func changeKind(of id: UUID, to kind: MediaKind) {
        update(id) {
            guard $0.kind != kind else { return }
            let parsed = ReleaseNameParser.parse(($0.path as NSString).lastPathComponent)
            $0.kind = kind
            $0.isMatched = false
            $0.artworkFile = nil
            $0.backdropFile = nil
            if kind == .episode {
                $0.showTitle = parsed.title
                $0.season = parsed.season ?? 1
                $0.episode = parsed.episode ?? 1
            } else if kind == .film {
                $0.title = parsed.title
                $0.showTitle = nil
                $0.season = nil
                $0.episode = nil
            }
        }
        refreshMetadata(for: [id])
    }
}
