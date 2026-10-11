import CryptoKit
import Foundation

struct MetadataMatch: Identifiable, Hashable {
    var id: String { "\(source)-\(tmdbID.map(String.init) ?? title)-\(year ?? 0)" }
    var title: String
    var year: Int?
    var overview: String?
    var genres: [String] = []
    var rating: Double?
    var posterURL: URL?
    var backdropURL: URL?
    var tmdbID: Int?
    var source: String
}

/// Looks up film, TV and album details. Uses TMDB when a key is set, otherwise the keyless iTunes Search API.
enum MetadataService {
    private static var tmdbKey: String { AppSettings.shared.tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    static var hasTMDB: Bool { !tmdbKey.isEmpty }

    // MARK: - Public lookups

    static func filmCandidates(query: String, year: Int? = nil) async -> [MetadataMatch] {
        if hasTMDB {
            var params = ["query": query]
            if let year { params["year"] = String(year) }
            var results = parseTMDB(await tmdb("search/movie", params), isTV: false)
            if results.isEmpty, year != nil { results = parseTMDB(await tmdb("search/movie", ["query": query]), isTV: false) }
            if !results.isEmpty { return results }
        }
        return parseITunes(await itunes(term: query, media: "movie", entity: "movie"), titleKey: "trackName")
    }

    static func showCandidates(query: String) async -> [MetadataMatch] {
        if hasTMDB {
            let results = parseTMDB(await tmdb("search/tv", ["query": query]), isTV: true)
            if !results.isEmpty { return results }
        }
        // iTunes lists seasons; collapse them to one entry per show.
        var seen = Set<String>()
        return parseITunes(await itunes(term: query, media: "tvShow", entity: "tvSeason"), titleKey: "artistName")
            .filter { seen.insert($0.title.lowercased()).inserted }
    }

    static func film(title: String, year: Int?) async -> MetadataMatch? {
        best(in: await filmCandidates(query: title, year: year), title: title, year: year)
    }

    static func show(title: String) async -> MetadataMatch? {
        best(in: await showCandidates(query: title), title: title, year: nil)
    }

    static func episode(showID: Int, season: Int, episode: Int) async -> (title: String?, overview: String?) {
        guard hasTMDB, let json = await tmdb("tv/\(showID)/season/\(season)/episode/\(episode)", [:]) else { return (nil, nil) }
        return (json["name"] as? String, json["overview"] as? String)
    }

    static func album(artist: String, album: String) async -> MetadataMatch? {
        let term = "\(artist) \(album)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        let results = parseITunes(await itunes(term: term, media: "music", entity: "album"), titleKey: "collectionName")
        return results.first { $0.title.lowercased() == album.lowercased() } ?? results.first
    }

    /// Prefers an exact title with the right year, then the service's own ranking.
    static func best(in candidates: [MetadataMatch], title: String, year: Int?) -> MetadataMatch? {
        let wanted = normalise(title)
        func score(_ m: MetadataMatch) -> Int {
            var s = 0
            let t = normalise(m.title)
            if t == wanted { s += 10 } else if t.hasPrefix(wanted) || wanted.hasPrefix(t) { s += 4 }
            if let year, let y = m.year { s += y == year ? 6 : (abs(y - year) == 1 ? 3 : -4) }
            return s
        }
        return candidates.enumerated().max { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa == sb ? a.offset > b.offset : sa < sb
        }?.element
    }

    static func normalise(_ title: String) -> String {
        title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Artwork

    /// Downloads an image into the artwork cache and returns its filename.
    static func downloadArtwork(from url: URL) async -> String? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let name = "\(digest).jpg"
        let destination = AppPaths.artwork.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return name }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 500 else { return nil }
        do {
            try data.write(to: destination, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    static func saveArtwork(_ data: Data) -> String? {
        let digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let name = "\(digest).jpg"
        let destination = AppPaths.artwork.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard (try? data.write(to: destination, options: .atomic)) != nil else { return nil }
        }
        return name
    }

    // MARK: - TMDB

    private static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary", 18: "Drama",
        10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Science Fiction", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
        10759: "Action & Adventure", 10762: "Kids", 10763: "News", 10764: "Reality", 10765: "Sci-Fi & Fantasy",
        10766: "Soap", 10767: "Talk", 10768: "War & Politics",
    ]

    private static func tmdb(_ path: String, _ params: [String: String]) async -> [String: Any]? {
        let key = tmdbKey
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        // v4 read tokens are JWTs and go in a header; v3 keys go in the query string.
        let isBearer = key.hasPrefix("eyJ")
        if !isBearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        if isBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func parseTMDB(_ json: [String: Any]?, isTV: Bool) -> [MetadataMatch] {
        (json?["results"] as? [[String: Any]] ?? []).prefix(12).compactMap { r in
            guard let title = (isTV ? r["name"] : r["title"]) as? String else { return nil }
            let date = (isTV ? r["first_air_date"] : r["release_date"]) as? String ?? ""
            func image(_ key: String, _ size: String) -> URL? {
                (r[key] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/\(size)\($0)") }
            }
            return MetadataMatch(
                title: title,
                year: Int(date.prefix(4)),
                overview: (r["overview"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                genres: (r["genre_ids"] as? [Int] ?? []).compactMap { genreNames[$0] },
                rating: (r["vote_average"] as? Double).flatMap { $0 > 0 ? $0 : nil },
                posterURL: image("poster_path", "w500"),
                backdropURL: image("backdrop_path", "w1280"),
                tmdbID: r["id"] as? Int,
                source: "tmdb"
            )
        }
    }

    // MARK: - iTunes

    private static func itunes(term: String, media: String, entity: String) async -> [String: Any]? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term), URLQueryItem(name: "media", value: media),
            URLQueryItem(name: "entity", value: entity), URLQueryItem(name: "limit", value: "10"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func parseITunes(_ json: [String: Any]?, titleKey: String) -> [MetadataMatch] {
        (json?["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let title = r[titleKey] as? String else { return nil }
            let artwork = (r["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            return MetadataMatch(
                title: title,
                year: Int((r["releaseDate"] as? String ?? "").prefix(4)),
                overview: (r["longDescription"] ?? r["shortDescription"]) as? String,
                genres: (r["primaryGenreName"] as? String).map { [$0] } ?? [],
                rating: nil,
                posterURL: artwork.flatMap(URL.init(string:)),
                backdropURL: nil,
                tmdbID: nil,
                source: "itunes"
            )
        }
    }
}
