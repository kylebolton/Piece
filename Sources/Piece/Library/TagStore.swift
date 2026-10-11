import Foundation
import SwiftUI

/// A user-defined label that can be attached to transfers and library items.
struct Tag: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorIndex: Int

    /// The palette tags are drawn from.
    static let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .blue, .indigo, .purple, .pink]
    var color: Color { Tag.palette[((colorIndex % Tag.palette.count) + Tag.palette.count) % Tag.palette.count] }
}

/// Tags and their assignments, persisted as `tags.json`. A target is either a library item
/// (`MediaItem.id.uuidString`) or a transfer (its info-hash), so tags survive either one being removed and re-added.
@MainActor
@Observable
final class TagStore {
    private(set) var tags: [Tag] = []
    private(set) var assignments: [String: Set<UUID>] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var tags: [Tag]
        var assignments: [String: [UUID]]
    }

    init(fileURL: URL = AppPaths.support.appendingPathComponent("tags.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            tags = snapshot.tags
            assignments = snapshot.assignments.mapValues(Set.init)
        }
    }

    // MARK: - Queries

    func tag(_ id: UUID) -> Tag? { tags.first { $0.id == id } }

    func tags(for target: String) -> [Tag] {
        guard let ids = assignments[target] else { return [] }
        return tags.filter { ids.contains($0.id) }
    }

    func has(_ tag: Tag, on target: String) -> Bool { assignments[target]?.contains(tag.id) == true }

    func targets(with tag: Tag) -> Set<String> {
        Set(assignments.filter { $0.value.contains(tag.id) }.keys)
    }

    func count(of tag: Tag) -> Int { assignments.values.reduce(0) { $0 + ($1.contains(tag.id) ? 1 : 0) } }

    /// Finds a tag by name, ignoring case and a leading "#".
    func tag(named name: String) -> Tag? {
        let key = TagStore.normalized(name)
        return tags.first { TagStore.normalized($0.name) == key }
    }

    nonisolated static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
    }

    // MARK: - Mutation

    @discardableResult
    func create(name: String) -> Tag? {
        let clean = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !clean.isEmpty else { return nil }
        if let existing = tag(named: clean) { return existing }
        let tag = Tag(name: clean, colorIndex: tags.count % Tag.palette.count)
        tags.append(tag)
        scheduleSave()
        return tag
    }

    func rename(_ tag: Tag, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let index = tags.firstIndex(of: tag) else { return }
        tags[index].name = clean
        scheduleSave()
    }

    func recolor(_ tag: Tag, to colorIndex: Int) {
        guard let index = tags.firstIndex(of: tag) else { return }
        tags[index].colorIndex = colorIndex
        scheduleSave()
    }

    func delete(_ tag: Tag) {
        tags.removeAll { $0.id == tag.id }
        for key in assignments.keys {
            assignments[key]?.remove(tag.id)
            if assignments[key]?.isEmpty == true { assignments[key] = nil }
        }
        scheduleSave()
    }

    func assign(_ tag: Tag, to targets: some Sequence<String>) {
        for target in targets { assignments[target, default: []].insert(tag.id) }
        scheduleSave()
    }

    func remove(_ tag: Tag, from targets: some Sequence<String>) {
        for target in targets {
            assignments[target]?.remove(tag.id)
            if assignments[target]?.isEmpty == true { assignments[target] = nil }
        }
        scheduleSave()
    }

    func toggle(_ tag: Tag, on targets: [String]) {
        if targets.allSatisfy({ has(tag, on: $0) }) { remove(tag, from: targets) } else { assign(tag, to: targets) }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let snapshot = Snapshot(tags: tags, assignments: assignments.mapValues { Array($0) })
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
