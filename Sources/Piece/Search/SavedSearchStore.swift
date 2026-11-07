import Foundation

/// A search the user bookmarked to run again later.
struct SavedSearch: Identifiable, Codable, Hashable {
    var id = UUID()
    var query: String
    var created = Date()
}

/// Bookmarked searches, persisted as `savedSearches.json`, newest first.
@MainActor
@Observable
final class SavedSearchStore {
    private(set) var searches: [SavedSearch] = []

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AppPaths.support.appendingPathComponent("savedSearches.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data) {
            searches = decoded
        }
    }

    nonisolated static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func saved(_ query: String) -> SavedSearch? {
        let key = Self.normalized(query)
        guard !key.isEmpty else { return nil }
        return searches.first { Self.normalized($0.query) == key }
    }

    func isSaved(_ query: String) -> Bool { saved(query) != nil }

    @discardableResult
    func add(_ query: String) -> SavedSearch? {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let existing = saved(clean) { return existing }
        let search = SavedSearch(query: clean)
        searches.insert(search, at: 0)
        save()
        return search
    }

    func remove(_ search: SavedSearch) {
        searches.removeAll { $0.id == search.id }
        save()
    }

    /// Bookmarks the query, or removes the bookmark if it's already saved.
    func toggle(_ query: String) {
        if let existing = saved(query) { remove(existing) } else { add(query) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(searches) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
