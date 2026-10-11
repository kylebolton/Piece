import Foundation

struct OnlineSubtitle: Identifiable, Hashable {
    var id: Int { fileID }
    var fileID: Int
    var language: String
    var release: String
    var downloads: Int
    var hashMatch: Bool
    var hearingImpaired: Bool
}

enum OpenSubtitlesError: LocalizedError {
    case missingKey
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your OpenSubtitles API key in Settings → Subtitles to search online."
        case .server(let message): message
        }
    }
}

/// Client for the OpenSubtitles.com REST API.
final class OpenSubtitles {
    static let shared = OpenSubtitles()

    private let base = URL(string: "https://api.opensubtitles.com/api/v1")!
    private var token: String?

    /// The OpenSubtitles "movie hash": file size plus the 64-bit sums of the first and last 64 KB.
    static func hash(size: UInt64, head: Data, tail: Data) -> String {
        var hash = size
        for chunk in [head, tail] {
            chunk.withUnsafeBytes { raw in
                let count = raw.count / 8
                for i in 0..<count {
                    hash = hash &+ UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    static let chunkSize = 65_536

    static func hash(fileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= UInt64(chunkSize) else { return nil }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: chunkSize)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(chunkSize))
        let tail = (try? handle.read(upToCount: chunkSize)) ?? Data()
        guard head.count == chunkSize, tail.count == chunkSize else { return nil }
        return hash(size: size, head: head, tail: tail)
    }

    private func request(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        let key = AppSettings.shared.openSubtitlesKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw OpenSubtitlesError.missingKey }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            // The API redirects unless parameters are lowercase and alphabetically sorted.
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value.lowercased()) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue("kTorrent v1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let message = json["message"] as? String ?? (json["errors"] as? [String])?.first
            throw OpenSubtitlesError.server(message ?? "OpenSubtitles returned an error (\(http.statusCode)).")
        }
        return json
    }

    /// Logging in is optional; it raises the daily download allowance.
    private func loginIfNeeded() async {
        let settings = AppSettings.shared
        guard token == nil, !settings.openSubtitlesUser.isEmpty, !settings.openSubtitlesPassword.isEmpty,
              let request = try? request("login", body: ["username": settings.openSubtitlesUser,
                                                         "password": settings.openSubtitlesPassword]) else { return }
        token = (try? await send(request))?["token"] as? String
    }

    func search(query: String?, movieHash: String?, season: Int? = nil, episode: Int? = nil,
                year: Int? = nil, languages: [String]) async throws -> [OnlineSubtitle] {
        var params: [String: String] = [:]
        if let query, !query.isEmpty { params["query"] = query }
        if let movieHash { params["moviehash"] = movieHash }
        if let season { params["season_number"] = String(season) }
        if let episode { params["episode_number"] = String(episode) }
        if let year, season == nil { params["year"] = String(year) }
        if !languages.isEmpty { params["languages"] = languages.sorted().joined(separator: ",") }
        guard params["query"] != nil || params["moviehash"] != nil else { return [] }

        let json = try await send(try request("subtitles", query: params))
        return Self.parseResults(json).sorted {
            if $0.hashMatch != $1.hashMatch { return $0.hashMatch }
            let l0 = languages.firstIndex(of: $0.language) ?? .max, l1 = languages.firstIndex(of: $1.language) ?? .max
            if l0 != l1 { return l0 < l1 }
            return $0.downloads > $1.downloads
        }
    }

    static func parseResults(_ json: [String: Any]) -> [OnlineSubtitle] {
        (json["data"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let attributes = entry["attributes"] as? [String: Any],
                  let file = (attributes["files"] as? [[String: Any]])?.first,
                  let fileID = file["file_id"] as? Int else { return nil }
            return OnlineSubtitle(
                fileID: fileID,
                language: (attributes["language"] as? String ?? "").lowercased(),
                release: attributes["release"] as? String ?? file["file_name"] as? String ?? "Subtitle",
                downloads: attributes["download_count"] as? Int ?? 0,
                hashMatch: attributes["moviehash_match"] as? Bool ?? false,
                hearingImpaired: attributes["hearing_impaired"] as? Bool ?? false
            )
        }
    }

    /// Downloads a subtitle and caches it on disk.
    func download(fileID: Int) async throws -> URL {
        let cached = AppPaths.subtitles.appendingPathComponent("os-\(fileID).srt")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        await loginIfNeeded()
        let json = try await send(try request("download", body: ["file_id": fileID]))
        guard let link = json["link"] as? String, let url = URL(string: link) else {
            throw OpenSubtitlesError.server(json["message"] as? String ?? "No download link was returned.")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        try data.write(to: cached, options: .atomic)
        return cached
    }
}
