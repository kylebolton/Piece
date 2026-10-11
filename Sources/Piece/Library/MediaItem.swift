import Foundation

enum MediaKind: String, Codable, CaseIterable {
    case film, episode, track, other
}

/// One entry in the media library.
struct MediaItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: MediaKind
    var path: String
    var title: String
    var dateAdded = Date()
    var fileSize: Int64 = 0
    var duration: Double = 0
    var year: Int?
    var overview: String?
    var genres: [String] = []
    var rating: Double?
    var artworkFile: String?
    var backdropFile: String?
    var tmdbID: Int?
    var resolution: String?
    var isMatched = false
    var torrentHash: String?

    // Storage: bytes saved by compression, and the archive holding this file if it has been packed.
    var savedBytes: Int64?
    var packedFile: String?
    var packedBytes: Int64?

    // TV
    var showTitle: String?
    var season: Int?
    var episode: Int?

    // Music
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?

    // Playback
    var isWatched = false
    var playPosition: Double = 0
    var playCount = 0
    var lastPlayed: Date?

    var url: URL { URL(fileURLWithPath: path) }
    var isPacked: Bool { packedFile != nil }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    var artworkURL: URL? { artworkFile.map { AppPaths.artwork.appendingPathComponent($0) } }
    var backdropURL: URL? { backdropFile.map { AppPaths.artwork.appendingPathComponent($0) } }

    var episodeCode: String {
        guard let season, let episode else { return "" }
        return String(format: "S%02dE%02d", season, episode)
    }

    var genreText: String { genres.joined(separator: ", ") }
    var yearText: String { year.map(String.init) ?? "" }

    // Sort keys for tables (non-optional so KeyPathComparator can use them).
    var sortTitle: String {
        let lower = title.lowercased()
        for article in ["the ", "a ", "an "] where lower.hasPrefix(article) { return String(lower.dropFirst(article.count)) }
        return lower
    }
    var sortArtist: String { (albumArtist ?? artist ?? "").lowercased() }
    var sortAlbum: String { (album ?? "").lowercased() }
    var sortYear: Int { year ?? 0 }
    var sortRating: Double { rating ?? 0 }
    var sortTrack: Int { (discNumber ?? 1) * 1000 + (trackNumber ?? 0) }
    var sortGenre: String { genres.first?.lowercased() ?? "" }

    /// Fraction watched, used for the progress bar on posters.
    var watchedFraction: Double {
        guard duration > 0, !isWatched else { return isWatched ? 1 : 0 }
        return min(1, playPosition / duration)
    }
}

struct Show: Identifiable, Hashable {
    var title: String
    var episodes: [MediaItem]

    var id: String { title.lowercased() }
    var artworkURL: URL? { episodes.first { $0.artworkFile != nil }?.artworkURL }
    var backdropURL: URL? { episodes.first { $0.backdropFile != nil }?.backdropURL }
    var overview: String? { episodes.first { $0.overview != nil }?.overview }
    var year: Int? { episodes.compactMap(\.year).min() }
    var seasons: [Int] { Array(Set(episodes.map { $0.season ?? 0 })).sorted() }
    var unwatchedCount: Int { episodes.filter { !$0.isWatched }.count }
    var dateAdded: Date { episodes.map(\.dateAdded).max() ?? .distantPast }

    func episodes(inSeason season: Int) -> [MediaItem] {
        episodes.filter { ($0.season ?? 0) == season }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }
}

struct Album: Identifiable, Hashable {
    var title: String
    var artist: String
    var tracks: [MediaItem]

    var id: String { "\(artist.lowercased())|\(title.lowercased())" }
    var artworkURL: URL? { tracks.first { $0.artworkFile != nil }?.artworkURL }
    var year: Int? { tracks.compactMap(\.year).first }
    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
}
