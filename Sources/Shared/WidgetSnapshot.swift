import Foundation

/// What the app shares with its widget: a small JSON file in the app group container.
struct WidgetSnapshot: Codable, Equatable {
    struct Transfer: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var progress: Double
        var status: String
        var isPaused: Bool
    }

    struct Recent: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var kind: String
    }

    var updated = Date()
    var downloadRate: Int
    var uploadRate: Int
    var activeCount: Int
    var transfers: [Transfer]
    var recents: [Recent]
    var savedBytes: Int64

    static let groupID = "group.me.kylebolton.piece"
    static let fileName = "widget.json"

    static var empty: WidgetSnapshot {
        WidgetSnapshot(downloadRate: 0, uploadRate: 0, activeCount: 0, transfers: [], recents: [], savedBytes: 0)
    }

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snapshot
    }

    func write() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
