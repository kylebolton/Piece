import Foundation

/// Parses RSS, Atom and Torznab feeds into search results.
final class FeedParser: NSObject, XMLParserDelegate {
    private var results: [SearchResult] = []
    private let provider: String
    private var inItem = false
    private var text = ""
    private var fields: [String: String] = [:]

    private static let dateFormats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ",
                                      "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss"]

    private init(provider: String) {
        self.provider = provider
    }

    static func parse(_ data: Data, provider: String) -> [SearchResult] {
        let delegate = FeedParser(provider: provider)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.results
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let element = name.lowercased()
        text = ""
        if element == "item" || element == "entry" {
            inItem = true
            fields = [:]
            return
        }
        guard inItem else { return }
        switch element {
        case "enclosure":
            fields["enclosure"] = attributes["url"]
            if let length = attributes["length"] { fields["enclosurelength"] = length }
        case "link":
            // Atom: <link href="…" rel="…"/>
            if let href = attributes["href"] {
                if attributes["rel"] == "enclosure" || attributes["type"]?.contains("bittorrent") == true {
                    fields["enclosure"] = href
                } else if fields["link"] == nil {
                    fields["link"] = href
                }
            }
        case "torznab:attr", "newznab:attr":
            if let key = attributes["name"]?.lowercased(), let value = attributes["value"] { fields["attr:\(key)"] = value }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(data: block, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = name.lowercased()
        guard inItem else { return }
        if element == "item" || element == "entry" {
            inItem = false
            if let result = makeResult() { results.append(result) }
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, fields[element] == nil { fields[element] = value }
    }

    private func first(_ keys: String...) -> String? {
        for key in keys { if let value = fields[key], !value.isEmpty { return value } }
        return nil
    }

    private func makeResult() -> SearchResult? {
        guard let title = fields["title"] else { return nil }
        let candidates = [first("attr:magneturl", "torrent:magneturi", "magneturi", "magnet"), fields["enclosure"],
                          fields["link"], fields["guid"], fields["id"]].compactMap { $0 }
        let magnet = candidates.first { $0.lowercased().hasPrefix("magnet:") }
        var hash = first("attr:infohash", "torrent:infohash", "nyaa:infohash", "infohash")?.lowercased()
        if hash == nil, let magnet { hash = Magnet.infoHash(from: magnet) }

        var torrentURL: URL?
        if let enclosure = fields["enclosure"], enclosure.lowercased().hasPrefix("http") {
            torrentURL = URL(string: enclosure)
        } else if let link = fields["link"], link.lowercased().hasPrefix("http"),
                  link.lowercased().contains(".torrent") || link.lowercased().contains("/download") {
            torrentURL = URL(string: link)
        }
        let details = [first("comments"), fields["guid"], fields["link"]].compactMap { $0 }
            .first { $0.lowercased().hasPrefix("http") && !$0.lowercased().contains(".torrent") }

        var size = first("attr:size", "size", "torrent:contentlength", "contentlength", "enclosurelength").flatMap { raw -> Int64? in
            Int64(raw) ?? SizeParser.bytes(in: raw)
        }
        if size == nil, let raw = fields["nyaa:size"] { size = SizeParser.bytes(in: raw) }
        if size == nil, let description = fields["description"] { size = SizeParser.bytes(in: description) }
        if let s = size, s <= 0 { size = nil }

        let seeders = first("attr:seeders", "torrent:seeds", "nyaa:seeders", "seeders", "seeds").flatMap(Int.init)
        var leechers = first("attr:leechers", "nyaa:leechers", "leechers", "leechs").flatMap(Int.init)
        if leechers == nil, let peers = first("attr:peers", "torrent:peers", "peers").flatMap(Int.init) {
            // Torznab "peers" counts everyone, including seeders.
            leechers = fields["attr:peers"] != nil ? max(0, peers - (seeders ?? 0)) : peers
        }

        var result = SearchResult(title: title, provider: provider)
        result.magnet = magnet ?? ((torrentURL == nil) ? hash.map { Magnet.make(infoHash: $0, name: title) } : nil)
        result.torrentURL = torrentURL
        result.detailsURL = details.flatMap(URL.init(string:))
        result.size = size
        result.seeders = seeders
        result.leechers = leechers
        result.infoHash = hash
        result.date = first("pubdate", "published", "updated", "dc:date").flatMap(Self.date(from:))
        guard result.magnet != nil || result.torrentURL != nil || result.detailsURL != nil else { return nil }
        return result
    }

    static func date(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return ISO8601DateFormatter().date(from: string)
    }
}
