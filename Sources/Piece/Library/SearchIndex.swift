import Foundation

/// A parsed search box: free-text words plus `#tag` filters.
struct SearchQuery: Equatable {
    var words: [String]
    var tagNames: [String]

    init(_ text: String) {
        var words: [String] = []
        var tags: [String] = []
        for token in text.lowercased().split(whereSeparator: \.isWhitespace) {
            if token.hasPrefix("#"), token.count > 1 { tags.append(String(token.dropFirst())) } else { words.append(String(token)) }
        }
        self.words = words
        self.tagNames = tags
    }

    var isEmpty: Bool { words.isEmpty && tagNames.isEmpty }
}

/// What can be searched: one library item or transfer, flattened to lowercase text.
struct SearchDocument {
    let target: String
    let text: String
    let tagNames: Set<String>
}

/// Substring-prefix matching over library items and transfers. Every word must match the start of some
/// word in the document, and every `#tag` must be present, so "bat 20" finds "The Batman (2022)".
enum SearchIndex {
    static func document(for item: MediaItem, tags: [Tag]) -> SearchDocument {
        let parts: [String?] = [item.title, item.showTitle, item.artist, item.album, item.albumArtist, item.yearText,
                                item.genreText, item.kind.rawValue, item.resolution, item.episodeCode]
        return SearchDocument(target: item.id.uuidString, text: parts.compactMap { $0 }.joined(separator: " ").lowercased(),
                              tagNames: Set(tags.map { TagStore.normalized($0.name) }))
    }

    static func document(for torrent: Torrent, tags: [Tag]) -> SearchDocument {
        SearchDocument(target: torrent.id, text: torrent.name.lowercased(), tagNames: Set(tags.map { TagStore.normalized($0.name) }))
    }

    static func matches(_ document: SearchDocument, _ query: SearchQuery) -> Bool {
        if query.isEmpty { return true }
        let tokens = document.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for word in query.words where !tokens.contains(where: { $0.hasPrefix(word) }) && !document.text.contains(word) {
            return false
        }
        for name in query.tagNames where !document.tagNames.contains(where: { $0.hasPrefix(name) }) { return false }
        return true
    }

    @MainActor static func matching(_ items: [MediaItem], _ query: SearchQuery, tags: TagStore) -> Set<UUID> {
        if query.isEmpty { return Set(items.map(\.id)) }
        return Set(items.filter { matches(document(for: $0, tags: tags.tags(for: $0.id.uuidString)), query) }.map(\.id))
    }
}
