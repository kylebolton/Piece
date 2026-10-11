import Foundation

struct SearchResult: Identifiable, Hashable {
    var title: String
    var magnet: String?
    var torrentURL: URL?
    var detailsURL: URL?
    var size: Int64?
    var seeders: Int?
    var leechers: Int?
    var date: Date?
    var provider: String
    var infoHash: String?

    var id: String {
        infoHash ?? magnet ?? torrentURL?.absoluteString ?? "\(provider)|\(detailsURL?.absoluteString ?? title)"
    }

    /// True when the download link still has to be read off the result's details page.
    var needsResolving: Bool { magnet == nil && torrentURL == nil }

    // Non-optional keys so the results table can sort on them.
    var sortSize: Int64 { size ?? -1 }
    var sortSeeders: Int { seeders ?? -1 }
    var sortLeechers: Int { leechers ?? -1 }
    var sortDate: Date { date ?? .distantPast }
}

struct SearchProvider: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case internetArchive, torznab, rss, html

        var label: String {
            switch self {
            case .internetArchive: "Internet Archive"
            case .torznab: "Torznab"
            case .rss: "RSS feed"
            case .html: "Web page"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    /// Torznab: the API endpoint. RSS / web page: a URL containing `{query}` (an RSS feed without it is filtered locally).
    var url: String
    var apiKey: String?
    var isEnabled = true
    var isBuiltIn = false

    var host: String { URL(string: url.replacingOccurrences(of: "{query}", with: "x"))?.host ?? url }
}

enum SearchError: LocalizedError {
    case badURL
    case http(Int)
    case noLink

    var errorDescription: String? {
        switch self {
        case .badURL: "The source's address isn't valid."
        case .http(let code): "The site answered with an error (\(code))."
        case .noLink: "No magnet or torrent link was found on that page."
        }
    }
}

enum Magnet {
    /// Extracts the info-hash (lowercase hex) from a magnet link, converting base32 hashes.
    static func infoHash(from magnet: String) -> String? {
        guard let match = magnet.firstMatch(of: /(?i)xt=urn:btih:([a-z0-9]+)/) else { return nil }
        let value = String(match.1)
        if value.count == 40, value.allSatisfy(\.isHexDigit) { return value.lowercased() }
        if value.count == 32 { return base32ToHex(value) }
        return nil
    }

    static func displayName(from magnet: String) -> String? {
        URLComponents(string: magnet)?.queryItems?.first { $0.name == "dn" }?.value?
            .replacingOccurrences(of: "+", with: " ")
    }

    static func make(infoHash: String, name: String?) -> String {
        var link = "magnet:?xt=urn:btih:\(infoHash)"
        if let name, let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            link += "&dn=\(encoded)"
        }
        return link
    }

    static func base32ToHex(_ string: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for character in string.uppercased() {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return bytes.count == 20 ? bytes.map { String(format: "%02x", $0) }.joined() : nil
    }
}

enum SizeParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?i)(\d{1,4}(?:[.,]\d{1,3})?)\s*(bytes|[kmgt]i?b)\b"#)

    /// Finds the first size such as "1.4 GB" or "700 MiB" in a piece of text.
    static func bytes(in text: String) -> Int64? {
        let ns = text as NSString
        guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let number = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        let multiplier: Double
        switch unit.first {
        case "k": multiplier = 1024
        case "m": multiplier = 1024 * 1024
        case "g": multiplier = 1024 * 1024 * 1024
        case "t": multiplier = 1024 * 1024 * 1024 * 1024
        default: multiplier = 1
        }
        return Int64(number * multiplier)
    }
}

extension HTTP {
    struct Page {
        var text: String
        var url: URL
        var contentType: String
        var status: Int

        var looksLikeFeed: Bool {
            let head = text.prefix(600).lowercased()
            return head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")
                || contentType.contains("rss") || contentType.contains("atom")
        }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: configuration)
    }()

    static func page(_ url: URL) async throws -> Page {
        let (data, response) = try await session.data(from: url)
        let http = response as? HTTPURLResponse
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return Page(text: text, url: response.url ?? url,
                    contentType: (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
                    status: http?.statusCode ?? 0)
    }
}
