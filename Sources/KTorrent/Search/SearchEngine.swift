import Foundation
import SwiftSoup

enum SearchEngine {
    static func search(_ query: String, provider: SearchProvider) async throws -> [SearchResult] {
        let results = try await listings(query, provider: provider)
        // Feeds such as BT4G's omit peer counts; ask the trackers instead.
        return await TrackerScraper.fill(results)
    }

    private static func listings(_ query: String, provider: SearchProvider) async throws -> [SearchResult] {
        switch provider.kind {
        case .internetArchive:
            return try await internetArchive(query, name: provider.name)
        case .torznab:
            guard var components = URLComponents(string: provider.url) else { throw SearchError.badURL }
            var items = (components.queryItems ?? []).filter { !["t", "q", "apikey", "limit"].contains($0.name) }
            items += [URLQueryItem(name: "t", value: "search"), URLQueryItem(name: "q", value: query),
                      URLQueryItem(name: "limit", value: "100")]
            if let key = provider.apiKey, !key.isEmpty { items.append(URLQueryItem(name: "apikey", value: key)) }
            components.queryItems = items
            guard let url = components.url else { throw SearchError.badURL }
            return FeedParser.parse(Data(try await fetch(url).text.utf8), provider: provider.name)
        case .rss:
            let page = try await fetch(try url(from: provider.url, query: query))
            let results = FeedParser.parse(Data(page.text.utf8), provider: provider.name)
            // A plain feed has no search of its own, so filter what it lists.
            return provider.url.contains("{query}") ? results : filter(results, query: query)
        case .html:
            let page = try await fetch(try url(from: provider.url, query: query))
            if page.looksLikeFeed { return FeedParser.parse(Data(page.text.utf8), provider: provider.name) }
            return HTMLScraper.scrape(html: page.text, baseURL: page.url, provider: provider.name, query: query)
        }
    }

    static func url(from template: String, query: String) throws -> URL {
        // Path-style templates ("/search/{query}/") need "/" escaped; query-string ones need "&" and "+" escaped.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?/#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        guard let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)) else { throw SearchError.badURL }
        return url
    }

    private static func fetch(_ url: URL) async throws -> HTTP.Page {
        let page = try await HTTP.page(url)
        guard page.status < 400 else { throw SearchError.http(page.status) }
        return page
    }

    static func filter(_ results: [SearchResult], query: String) -> [SearchResult] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return results }
        return results.filter { result in
            let title = result.title.lowercased()
            return tokens.allSatisfy { title.contains($0) }
        }
    }

    /// Reads the magnet or .torrent link off a result's details page.
    static func resolve(_ result: SearchResult) async throws -> String {
        if let magnet = result.magnet { return magnet }
        if let url = result.torrentURL { return url.absoluteString }
        guard let details = result.detailsURL else { throw SearchError.noLink }
        let page = try await fetch(details)
        let link = HTMLScraper.downloadLink(html: page.text, baseURL: page.url)
        if let magnet = link.magnet { return magnet }
        if let torrent = link.torrent { return torrent.absoluteString }
        throw SearchError.noLink
    }

    // MARK: - Internet Archive

    static func internetArchive(_ query: String, name: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        var items = [URLQueryItem(name: "q", value: internetArchiveQuery(query))]
        for field in ["identifier", "title", "item_size", "downloads", "publicdate", "mediatype"] {
            items.append(URLQueryItem(name: "fl[]", value: field))
        }
        items += [URLQueryItem(name: "sort[]", value: "downloads desc"), URLQueryItem(name: "rows", value: "75"),
                  URLQueryItem(name: "output", value: "json")]
        components.queryItems = items
        let page = try await fetch(components.url!)
        return parseInternetArchive(Data(page.text.utf8), name: name)
    }

    /// Matches every word against item titles; searching all metadata returns mostly unrelated items.
    static func internetArchiveQuery(_ query: String) -> String {
        let words = query.split(whereSeparator: { $0.isWhitespace })
            .map { $0.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "'" } }
            .filter { !$0.isEmpty }
        let title = words.isEmpty ? "*" : words.joined(separator: " AND ")
        return "title:(\(title)) AND format:(\"Archive BitTorrent\")"
    }

    static func parseInternetArchive(_ data: Data, name: String) -> [SearchResult] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = (root["response"] as? [String: Any])?["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { doc in
            guard let identifier = doc["identifier"] as? String else { return nil }
            let title = (doc["title"] as? String) ?? (doc["title"] as? [String])?.first ?? identifier
            var result = SearchResult(title: title, provider: name)
            let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
            result.torrentURL = URL(string: "https://archive.org/download/\(encoded)/\(encoded)_archive.torrent")
            result.detailsURL = URL(string: "https://archive.org/details/\(encoded)")
            result.size = (doc["item_size"] as? NSNumber)?.int64Value
            result.date = (doc["publicdate"] as? String).flatMap(FeedParser.date(from:))
            return result
        }
    }
}

/// Works out how to search a site the user typed in.
enum SiteDetector {
    struct Outcome {
        var provider: SearchProvider
        var sample: [SearchResult]
    }

    private static let queryParameterNames: Set<String> = [
        "q", "query", "search", "s", "keyword", "keywords", "term", "k", "nm", "text", "searchterm", "search_query", "name", "f",
    ]

    private static let commonPatterns = [
        "/search?q={query}&page=rss", "/search?q={query}", "/search/{query}", "/?s={query}", "/search.php?q={query}", "/torrents?search={query}",
        "/search/?search={query}", "/search/{query}/1/", "/?q={query}", "/torrents.php?search={query}", "/search?query={query}",
    ]

    static func detect(input: String, testQuery: String, apiKey: String? = nil,
                       log: @escaping @MainActor (String) -> Void) async -> Outcome? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        text = text.replacingOccurrences(of: "%s", with: "{query}")
        guard let inputURL = URL(string: text.replacingOccurrences(of: "{query}", with: "QUERYPLACEHOLDER")),
              let host = inputURL.host else {
            await log("That doesn't look like a web address.")
            return nil
        }
        let name = host.replacingOccurrences(of: "www.", with: "")
        let origin = "\(inputURL.scheme ?? "https")://\(host)\(inputURL.port.map { ":\($0)" } ?? "")"

        // 1. The user gave a search URL template directly.
        if text.contains("{query}") {
            await log("Using the address as a search template…")
            if let outcome = await tryTemplate(text, name: name, testQuery: testQuery, log: log) { return outcome }
        }

        // 2. Torznab (Jackett, Prowlarr and compatible indexers).
        if let outcome = await tryTorznab(inputURL, name: name, apiKey: apiKey, testQuery: testQuery, log: log) { return outcome }

        // 3. Look at the page itself.
        await log("Loading \(host)…")
        var loaded: HTTP.Page?
        if let page = try? await HTTP.page(inputURL), page.status < 400 {
            loaded = page
        } else {
            // Sites behind a bot challenge refuse the home page but may still serve their RSS or API endpoints.
            await log("Couldn't load the page itself; trying the site's known search addresses…")
        }
        if let page = loaded, page.looksLikeFeed {
            let results = FeedParser.parse(Data(page.text.utf8), provider: name)
            if !results.isEmpty {
                await log("Found an RSS feed with \(results.count) torrents.")
                return Outcome(provider: SearchProvider(name: name, kind: .rss, url: inputURL.absoluteString), sample: results)
            }
        }

        var templates: [String] = []

        // A pasted results URL such as "…/search?q=ubuntu": swap the search term for a placeholder.
        if var components = URLComponents(url: inputURL, resolvingAgainstBaseURL: false), let items = components.queryItems,
           let index = items.firstIndex(where: { queryParameterNames.contains($0.name.lowercased()) && !($0.value ?? "").isEmpty }) {
            var replaced = items
            replaced[index].value = "QUERYPLACEHOLDER"
            components.queryItems = replaced
            if let string = components.string { templates.append(string.replacingOccurrences(of: "QUERYPLACEHOLDER", with: "{query}")) }
        }

        if let page = loaded, let document = try? SwiftSoup.parse(page.text, page.url.absoluteString) {
            // OpenSearch description, the same thing browsers use to add a site as a search engine.
            if let link = try? document.select("link[rel=search]").first(), let href = try? link.absUrl("href"),
               let url = URL(string: href), let description = try? await HTTP.page(url) {
                await log("Reading the site's search description…")
                for match in description.text.matches(of: /(?i)<Url[^>]*template="([^"]+)"[^>]*>/) {
                    let tag = String(match.0).lowercased()
                    var template = String(match.1).replacingOccurrences(of: "&amp;", with: "&")
                    guard template.contains("{searchTerms}"), !tag.contains("suggestions") else { continue }
                    template = template.replacingOccurrences(of: "{searchTerms}", with: "{query}")
                        .replacingOccurrences(of: #"\{[a-zA-Z:]+\??\}"#, with: "", options: .regularExpression)
                    if tag.contains("rss") || tag.contains("atom") { templates.insert(template, at: 0) } else { templates.append(template) }
                }
            }
            // Search forms on the page.
            for form in (try? document.select("form").array()) ?? [] {
                guard ((try? form.attr("method")) ?? "").lowercased() != "post" else { continue }
                let inputs = (try? form.select("input").array()) ?? []
                guard let field = inputs.first(where: { input in
                    let type = ((try? input.attr("type")) ?? "text").lowercased()
                    let name = ((try? input.attr("name")) ?? "").lowercased()
                    return !name.isEmpty && (type == "search" || (["text", ""].contains(type) && queryParameterNames.contains(name)))
                }), let fieldName = try? field.attr("name") else { continue }
                var action = (try? form.absUrl("action")) ?? ""
                if action.isEmpty { action = page.url.absoluteString }
                var parts = ["\(fieldName)={query}"]
                for hidden in inputs where ((try? hidden.attr("type")) ?? "").lowercased() == "hidden" {
                    if let n = try? hidden.attr("name"), !n.isEmpty, let v = try? hidden.attr("value") {
                        parts.append("\(n)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)")
                    }
                }
                templates.append(action + (action.contains("?") ? "&" : "?") + parts.joined(separator: "&"))
            }
        }
        templates += commonPatterns.map { origin + $0 }

        // A form that posts to another site (a web search engine, say) isn't this site's search.
        templates = templates.filter { URL(string: $0.replacingOccurrences(of: "{query}", with: "x"))?.host == host }

        var tried = Set<String>()
        for template in templates where tried.insert(template).inserted {
            if let outcome = await tryTemplate(template, name: name, testQuery: testQuery, log: log) { return outcome }
        }
        await log("Couldn't find a working search on \(host). Try pasting the address of a results page, or a URL with {query} where the search term goes.")
        return nil
    }

    private static func tryTemplate(_ template: String, name: String, testQuery: String,
                                    log: @escaping @MainActor (String) -> Void) async -> Outcome? {
        guard let url = try? SearchEngine.url(from: template, query: testQuery) else { return nil }
        await log("Trying \(template.replacingOccurrences(of: "https://", with: ""))")
        guard let page = try? await HTTP.page(url), page.status < 400 else { return nil }
        if page.looksLikeFeed {
            let results = FeedParser.parse(Data(page.text.utf8), provider: name)
            guard !results.isEmpty else { return nil }
            await log("Found \(results.count) results in a feed.")
            return Outcome(provider: SearchProvider(name: name, kind: .rss, url: template), sample: results)
        }
        let results = HTMLScraper.scrape(html: page.text, baseURL: page.url, provider: name, query: testQuery)
        // A search page that ignores the query returns links unrelated to it.
        let relevant = SearchEngine.filter(results, query: testQuery)
        guard results.count >= 2, relevant.count * 3 >= results.count else { return nil }
        // When results only link to detail pages, make sure a download link can really be read from one.
        if let first = results.first, first.needsResolving {
            await log("Checking a result page for a download link…")
            guard (try? await SearchEngine.resolve(first)) != nil else { return nil }
        }
        await log("Found \(results.count) results.")
        return Outcome(provider: SearchProvider(name: name, kind: .html, url: template), sample: results)
    }

    private static func tryTorznab(_ url: URL, name: String, apiKey: String?, testQuery: String,
                                   log: @escaping @MainActor (String) -> Void) async -> Outcome? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let key = apiKey?.isEmpty == false ? apiKey : components.queryItems?.first { $0.name.lowercased() == "apikey" }?.value
        components.queryItems = nil
        var endpoints: [String] = []
        let path = components.path
        if path.lowercased().contains("/api") {
            endpoints.append(components.string ?? "")
        } else {
            components.path = (path.hasSuffix("/") ? String(path.dropLast()) : path) + "/api"
            endpoints.append(components.string ?? "")
        }
        for endpoint in endpoints where !endpoint.isEmpty {
            guard var caps = URLComponents(string: endpoint) else { continue }
            caps.queryItems = [URLQueryItem(name: "t", value: "caps")] + (key.map { [URLQueryItem(name: "apikey", value: $0)] } ?? [])
            guard let capsURL = caps.url, let page = try? await HTTP.page(capsURL), page.status < 400,
                  page.text.lowercased().contains("<caps") else { continue }
            await log("Found a Torznab indexer.")
            var provider = SearchProvider(name: name, kind: .torznab, url: endpoint)
            provider.apiKey = key
            if let title = page.text.firstMatch(of: /(?i)<server[^>]*title="([^"]+)"/) { provider.name = String(title.1) }
            let sample = (try? await SearchEngine.search(testQuery, provider: provider)) ?? []
            await log(sample.isEmpty ? "The indexer answered but returned nothing for “\(testQuery)”." : "Found \(sample.count) results.")
            return Outcome(provider: provider, sample: sample)
        }
        return nil
    }
}

/// The list of search sources and the state of the current search.
@MainActor
@Observable
final class SearchStore {
    private(set) var providers: [SearchProvider] = []
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var failures: [String: String] = [:]
    private(set) var pending: Set<String> = []
    var query = ""

    @ObservationIgnored private let fileURL = AppPaths.support.appendingPathComponent("sources.json")
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    static let builtIn: [SearchProvider] = [
        SearchProvider(id: UUID(uuidString: "0A1C7C58-5B0B-4C1E-9C55-000000000001")!, name: "Internet Archive",
                       kind: .internetArchive, url: "https://archive.org", isBuiltIn: true),
        SearchProvider(id: UUID(uuidString: "0A1C7C58-5B0B-4C1E-9C55-000000000002")!, name: "Linux Tracker",
                       kind: .html, url: "https://linuxtracker.org/torrents/?q={query}", isBuiltIn: true),
    ]

    init() {
        var loaded: [SearchProvider] = []
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([SearchProvider].self, from: data) {
            loaded = decoded
        }
        // Built-ins always exist; the saved copy only carries whether they're switched on.
        for provider in Self.builtIn.reversed() {
            if let index = loaded.firstIndex(where: { $0.id == provider.id }) {
                var updated = provider
                updated.isEnabled = loaded[index].isEnabled
                loaded[index] = updated
            } else {
                loaded.insert(provider, at: 0)
            }
        }
        providers = loaded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(providers) { try? data.write(to: fileURL, options: .atomic) }
    }

    func add(_ provider: SearchProvider) {
        providers.append(provider)
        save()
    }

    func update(_ provider: SearchProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        save()
    }

    func remove(_ provider: SearchProvider) {
        providers.removeAll { $0.id == provider.id && !$0.isBuiltIn }
        save()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[index].isEnabled = enabled
        save()
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()
        results = []
        failures = [:]
        guard !text.isEmpty else {
            isSearching = false
            pending = []
            return
        }
        let active = providers.filter(\.isEnabled)
        isSearching = true
        pending = Set(active.map(\.name))
        searchTask = Task {
            await withTaskGroup(of: (String, Result<[SearchResult], Error>).self) { group in
                for provider in active {
                    group.addTask {
                        do { return (provider.name, .success(try await SearchEngine.search(text, provider: provider))) }
                        catch { return (provider.name, .failure(error)) }
                    }
                }
                for await (name, outcome) in group {
                    guard !Task.isCancelled else { return }
                    pending.remove(name)
                    switch outcome {
                    case .success(let found): merge(found)
                    case .failure(let error): failures[name] = error.localizedDescription
                    }
                }
            }
            guard !Task.isCancelled else { return }
            isSearching = false
        }
    }

    /// Adds results, dropping torrents another source already returned.
    private func merge(_ found: [SearchResult]) {
        var seen = Set(results.map(\.id))
        results.append(contentsOf: found.filter { seen.insert($0.id).inserted })
    }
}
