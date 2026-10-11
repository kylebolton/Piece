import Foundation
import SwiftSoup

/// Template-free scraper: finds the repeating rows of a search results page and reads the
/// title, download link, size and seeder counts out of each one.
enum HTMLScraper {
    static func scrape(html: String, baseURL: URL, provider: String, query: String = "") -> [SearchResult] {
        guard let document = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return [] }
        let direct = directLinkResults(in: document, provider: provider)
        if !direct.isEmpty { return direct }
        return detailLinkResults(in: document, baseURL: baseURL, provider: provider, query: query)
    }

    /// The first magnet or .torrent link on a details page.
    static func downloadLink(html: String, baseURL: URL) -> (magnet: String?, torrent: URL?) {
        guard let document = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return (nil, nil) }
        let anchors = (try? document.select("a[href]").array()) ?? []
        if let magnet = anchors.lazy.compactMap({ try? $0.attr("href") }).first(where: { $0.lowercased().hasPrefix("magnet:") }) {
            return (magnet, nil)
        }
        if let match = html.firstMatch(of: /magnet:\?xt=urn:bt[a-z0-9]+:[^"'<\s]+/) {
            return (String(match.0).replacingOccurrences(of: "&amp;", with: "&"), nil)
        }
        for anchor in anchors where isTorrentLink((try? anchor.attr("href")) ?? "") {
            if let url = (try? anchor.absUrl("href")).flatMap(URL.init(string:)) { return (nil, url) }
        }
        return (nil, nil)
    }

    // MARK: - Pages that list magnet / .torrent links directly

    private static func isTorrentLink(_ href: String) -> Bool {
        let lower = href.lowercased()
        guard !lower.hasPrefix("magnet:") else { return false }
        let path = lower.split(separator: "?").first.map(String.init) ?? lower
        return path.hasSuffix(".torrent") || lower.contains(".torrent?") || lower.contains("/download.php?")
            || lower.contains("/torrent/download/")
    }

    private static func directLinkResults(in document: Document, provider: String) -> [SearchResult] {
        let anchors = (try? document.select("a[href]").array()) ?? []
        var rows: [Element] = []
        var seen = Set<ObjectIdentifier>()
        var links: [ObjectIdentifier: (magnet: String?, torrent: URL?)] = [:]

        for anchor in anchors {
            let href = (try? anchor.attr("href")) ?? ""
            let isMagnet = href.lowercased().hasPrefix("magnet:")
            guard isMagnet || isTorrentLink(href) else { continue }
            let row = container(of: anchor)
            let key = ObjectIdentifier(row)
            if seen.insert(key).inserted { rows.append(row) }
            var entry = links[key] ?? (nil, nil)
            if isMagnet {
                entry.magnet = entry.magnet ?? href
            } else if entry.torrent == nil {
                entry.torrent = (try? anchor.absUrl("href")).flatMap(URL.init(string:))
            }
            links[key] = entry
        }
        guard !rows.isEmpty else { return [] }

        return rows.compactMap { row in
            guard let link = links[ObjectIdentifier(row)] else { return nil }
            let titleAnchor = titleAnchor(in: row)
            var title = (try? titleAnchor?.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let attribute = try? titleAnchor?.attr("title"), attribute.count > title.count { title = attribute }
            if title.count < 3, let magnet = link.magnet { title = Magnet.displayName(from: magnet) ?? "" }
            if title.count < 3, let url = link.torrent { title = url.deletingPathExtension().lastPathComponent }
            guard title.count >= 3 else { return nil }

            var result = SearchResult(title: title, provider: provider)
            result.magnet = link.magnet
            result.torrentURL = link.torrent
            result.infoHash = link.magnet.flatMap(Magnet.infoHash(from:))
            result.detailsURL = (try? titleAnchor?.absUrl("href")).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            fillStats(&result, from: row)
            return result
        }
    }

    /// Climbs from a link to the element that represents its whole result row.
    private static func container(of anchor: Element) -> Element {
        var current = anchor
        var fallback: Element?
        for _ in 0..<8 {
            guard let parent = current.parent() else { break }
            let tag = parent.tagName().lowercased()
            if ["tr", "li", "article", "dd"].contains(tag) { return parent }
            if tag == "body" || tag == "table" || tag == "tbody" || tag == "ul" || tag == "ol" { break }
            // A div among several like-classed siblings is a card in a list of cards.
            if fallback == nil, tag == "div", let grand = parent.parent() {
                let cls = (try? parent.className()) ?? ""
                let similar = grand.children().array().filter {
                    $0.tagName().lowercased() == "div" && ((try? $0.className()) ?? "") == cls
                }.count
                if similar >= 3 { fallback = parent }
            }
            current = parent
        }
        return fallback ?? anchor.parent() ?? anchor
    }

    private static func titleAnchor(in row: Element) -> Element? {
        let anchors = (try? row.select("a[href]").array()) ?? []
        var best: Element?
        var bestLength = 0
        for anchor in anchors {
            let href = ((try? anchor.attr("href")) ?? "").lowercased()
            if href.hasPrefix("magnet:") || href.hasPrefix("javascript:") || href == "#" { continue }
            let text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespaces)
            let length = max(text.count, isTorrentLink(href) ? 0 : ((try? anchor.attr("title")) ?? "").count)
            if length > bestLength {
                best = anchor
                bestLength = length
            }
        }
        return bestLength >= 3 ? best : nil
    }

    // MARK: - Size, seeders, leechers

    private static func fillStats(_ result: inout SearchResult, from row: Element) {
        let rowText = (try? row.text()) ?? ""
        let withoutTitle = rowText.replacingOccurrences(of: result.title, with: " ")
        result.size = SizeParser.bytes(in: withoutTitle)

        // 1. Elements labelled by class name.
        for (keywords, keyPath) in [(["seed"], \SearchResult.seeders), (["leech", "peer"], \SearchResult.leechers)] {
            for keyword in keywords where result[keyPath: keyPath] == nil {
                if let element = try? row.select("[class*=\(keyword)]").first(), let value = integer(try? element.text()) {
                    result[keyPath: keyPath] = value
                }
            }
        }
        guard result.seeders == nil, row.tagName().lowercased() == "tr" else { return }
        let cells = row.children().array().filter { ["td", "th"].contains($0.tagName().lowercased()) }

        // 2. Table header names.
        let tableRows = ancestor(of: row, tag: "table").flatMap { try? $0.select("tr").array() } ?? []
        if let header = tableRows.first(where: { ((try? $0.select("th").size()) ?? 0) >= 2 }) {
            let headers = header.children().array().map { ((try? $0.text()) ?? "").lowercased().trimmingCharacters(in: .whitespaces) }
            if headers.count == cells.count {
                for (index, name) in headers.enumerated() {
                    if result.seeders == nil, name.hasPrefix("seed") || name == "se" || name == "s" || name == "↑" {
                        result.seeders = integer(try? cells[index].text())
                    } else if result.leechers == nil, name.hasPrefix("leech") || name.hasPrefix("peer") || name == "le" || name == "l" || name == "↓" {
                        result.leechers = integer(try? cells[index].text())
                    }
                }
            }
        }
        // 3. The first two cells that are bare numbers after the size column.
        if result.seeders == nil {
            var afterSize = result.size == nil
            var numbers: [Int] = []
            for cell in cells {
                let text = ((try? cell.text()) ?? "").trimmingCharacters(in: .whitespaces)
                if !afterSize {
                    if SizeParser.bytes(in: text) != nil, text.count < 16 { afterSize = true }
                    continue
                }
                if text.count <= 9, let value = integer(text) { numbers.append(value) }
            }
            if numbers.count >= 2 {
                result.seeders = numbers[0]
                result.leechers = numbers[1]
            }
        }
    }

    /// Reads a count from a cell, tolerating extras such as "8 +141 ext" or "1,204".
    private static func integer(_ text: String?) -> Int? {
        guard let text, let match = text.trimmingCharacters(in: .whitespaces).firstMatch(of: /^(\d[\d,]{0,10})(?:\s|$)/) else { return nil }
        return Int(match.1.replacingOccurrences(of: ",", with: ""))
    }

    private static func ancestor(of element: Element, tag: String) -> Element? {
        var current = element.parent()
        while let node = current {
            if node.tagName().lowercased() == tag { return node }
            current = node.parent()
        }
        return nil
    }

    // MARK: - Pages that only link to a details page per result

    private static func detailLinkResults(in document: Document, baseURL: URL, provider: String, query: String) -> [SearchResult] {
        let tokens = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !tokens.isEmpty else { return [] }
        let anchors = (try? document.select("a[href]").array()) ?? []
        var groups: [String: [(Element, URL, String)]] = [:]
        var seen = Set<String>()

        for anchor in anchors {
            guard let url = (try? anchor.absUrl("href")).flatMap(URL.init(string:)), url.host == baseURL.host else { continue }
            var text = ((try? anchor.text()) ?? "").trimmingCharacters(in: .whitespaces)
            if let title = try? anchor.attr("title"), title.count > text.count { text = title }
            let lower = text.lowercased()
            guard text.count >= 6, tokens.allSatisfy({ lower.contains($0) }), seen.insert(url.absoluteString).inserted else { continue }
            // Result links share a path shape: "/torrent/123/name" → "/torrent/#/*".
            let shape = url.pathComponents.dropFirst().prefix(2).enumerated().map { index, part in
                part.allSatisfy(\.isNumber) ? "#" : (index == 0 ? part : "*")
            }.joined(separator: "/") + (url.query == nil ? "" : "?")
            groups[shape, default: []].append((anchor, url, text))
        }
        guard let best = groups.values.max(by: { $0.count < $1.count }), best.count >= 2 else { return [] }

        return best.map { anchor, url, text in
            var result = SearchResult(title: text, provider: provider)
            result.detailsURL = url
            // Many sites key their pages by info-hash, which lets duplicates from other sources collapse.
            result.infoHash = url.pathComponents.first { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
            fillStats(&result, from: container(of: anchor))
            return result
        }
    }
}
