import Foundation
import UserNotifications

/// What happens to a torrent file once it has been added from the watched folder.
enum WatchFolderAction: String, CaseIterable {
    case keep, trash
}

/// Adds the `.torrent` files in a chosen folder, at launch and whenever the folder changes.
/// A transfer that already exists keeps going and just picks up the file's trackers.
@MainActor
final class WatchFolder {
    private let settings: AppSettings
    private let torrents: TorrentStore
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    /// Failed reads per file: a file still being copied in may not be a complete torrent yet.
    private var failures: [String: Int] = [:]
    private static let maxFailures = 5
    private static let seenKey = "watchFolderSeen"

    init(settings: AppSettings, torrents: TorrentStore) {
        self.settings = settings
        self.torrents = torrents
    }

    /// Starts, moves or stops watching to match the settings.
    func restart() {
        source?.cancel()
        source = nil
        pending?.cancel()
        failures = [:]
        guard settings.watchFolderEnabled, !AppPaths.isTesting, !DemoTorrents.isEnabled else { return }
        let fd = open(settings.watchFolder, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.scan(after: 1) } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        scan(after: 0)
    }

    /// Looks at the folder after a short pause, so a burst of changes becomes one pass.
    private func scan(after delay: Double) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.scanNow()
        }
    }

    private func scanNow() {
        let folder = URL(fileURLWithPath: settings.watchFolder, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        let candidates = files.filter { $0.pathExtension.lowercased() == "torrent" }

        // Files that are kept stay in the folder, so remember which ones were already added.
        // Otherwise a transfer the user removed would come back on every launch.
        var seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: String] ?? [:]
        let before = seen
        seen = seen.filter { entry in candidates.contains { $0.path == entry.key } }
        var retry = false
        var added: [String] = []

        for url in candidates {
            let signature = Self.signature(of: url)
            if seen[url.path] == signature { continue }
            if let data = try? Data(contentsOf: url), torrents.add(torrentData: data, reportErrors: false) != nil {
                failures[url.path] = nil
                added.append(url.deletingPathExtension().lastPathComponent)
                if settings.watchFolderAction == .trash {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } else {
                    seen[url.path] = signature
                }
                continue
            }
            let count = failures[url.path, default: 0] + 1
            failures[url.path] = count
            if count < Self.maxFailures {
                retry = true
            } else {
                seen[url.path] = signature
                torrents.lastError = "Couldn't add “\(url.lastPathComponent)” from the watched folder."
            }
        }

        if seen != before { UserDefaults.standard.set(seen, forKey: Self.seenKey) }
        if !added.isEmpty, settings.watchFolderNotify { notify(added) }
        if retry { scan(after: 3) }
    }

    private func notify(_ names: [String]) {
        let content = UNMutableNotificationContent()
        content.title = names.count == 1 ? "Torrent added" : "\(names.count) torrents added"
        content.body = names.count == 1 ? names[0] : names.prefix(3).joined(separator: "\n") + (names.count > 3 ? "\n…" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func signature(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(values?.fileSize ?? 0)"
    }
}
