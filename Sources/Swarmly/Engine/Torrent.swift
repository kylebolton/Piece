import Foundation

enum TorrentPhase: String {
    case fetchingMetadata, checking, downloading, seeding, completed, paused, queued, error

    var label: String {
        switch self {
        case .fetchingMetadata: "Fetching info"
        case .checking: "Checking"
        case .downloading: "Downloading"
        case .seeding: "Seeding"
        case .completed: "Completed"
        case .paused: "Paused"
        case .queued: "Queued"
        case .error: "Error"
        }
    }
}

/// Live state of one torrent, refreshed once a second by `TorrentStore`.
@Observable
final class Torrent: Identifiable, Hashable {
    let id: String
    var name: String
    var savePath = ""
    var phase: TorrentPhase = .fetchingMetadata
    var errorMessage: String?
    var hasMetadata = false
    var isComplete = false
    var progress: Double = 0
    var totalSize: Int64 = 0
    var totalWanted: Int64 = 0
    var totalWantedDone: Int64 = 0
    var totalDownloaded: Int64 = 0
    var totalUploaded: Int64 = 0
    var downloadRate = 0
    var uploadRate = 0
    var peers = 0
    var seeds = 0
    var pieceCount = 0
    var pieceLength = 0
    var dateAdded = Date()
    var speedHistory: [SpeedSample] = []

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    static func == (lhs: Torrent, rhs: Torrent) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isPaused: Bool { phase == .paused }
    var isActive: Bool { phase == .downloading || phase == .fetchingMetadata || phase == .checking || phase == .queued }

    var etaSeconds: Double? {
        guard phase == .downloading, downloadRate > 0 else { return nil }
        return Double(totalWanted - totalWantedDone) / Double(downloadRate)
    }

    var statusLine: String {
        switch phase {
        case .fetchingMetadata:
            return peers > 0 ? "Fetching torrent info from \(peers) peer\(peers == 1 ? "" : "s")…" : "Looking for peers…"
        case .checking:
            return "Checking files — \(Format.percent(progress))"
        case .downloading:
            var parts = ["\(Format.bytes(totalWantedDone)) of \(Format.bytes(totalWanted))"]
            parts.append("↓ \(Format.rate(downloadRate))")
            if uploadRate > 0 { parts.append("↑ \(Format.rate(uploadRate))") }
            parts.append("\(peers) peer\(peers == 1 ? "" : "s")")
            if let eta = etaSeconds { parts.append("\(Format.eta(seconds: eta)) left") }
            return parts.joined(separator: "  ·  ")
        case .seeding:
            return "\(Format.bytes(totalWanted))  ·  ↑ \(Format.rate(uploadRate))  ·  Ratio \(Format.ratio(uploaded: totalUploaded, downloaded: max(totalDownloaded, totalWanted)))"
        case .completed:
            return "\(Format.bytes(totalWanted))  ·  Completed"
        case .paused:
            return hasMetadata ? "\(Format.bytes(totalWantedDone)) of \(Format.bytes(totalWanted))  ·  Paused" : "Paused"
        case .queued:
            return "Waiting in queue"
        case .error:
            return errorMessage ?? "Something went wrong"
        }
    }

    func apply(_ s: KTTorrentStatus) {
        // Assign only on change so views that don't depend on a value aren't invalidated every tick.
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Torrent, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        set(\.name, s.name)
        set(\.savePath, s.savePath)
        set(\.hasMetadata, s.hasMetadata)
        set(\.progress, Double(s.progress))
        set(\.totalSize, s.totalSize)
        set(\.totalWanted, s.totalWanted)
        set(\.totalWantedDone, s.totalWantedDone)
        set(\.totalDownloaded, s.totalDownloaded)
        set(\.totalUploaded, s.totalUploaded)
        set(\.downloadRate, Int(s.downloadRate))
        set(\.uploadRate, Int(s.uploadRate))
        set(\.peers, Int(s.numPeers))
        set(\.seeds, Int(s.numSeeds))
        set(\.pieceCount, Int(s.numPieces))
        set(\.pieceLength, Int(s.pieceLength))
        set(\.errorMessage, s.errorMessage)
        if s.addedTime > 0 { set(\.dateAdded, Date(timeIntervalSince1970: s.addedTime)) }

        let done = s.state == .finished || s.state == .seeding
        set(\.isComplete, done)

        let phase: TorrentPhase
        if s.errorMessage != nil {
            phase = .error
        } else if s.paused && !s.autoManaged {
            phase = done ? .completed : .paused
        } else if s.state == .checking {
            phase = .checking
        } else if s.paused {
            phase = done ? .completed : .queued
        } else if s.state == .fetchingMetadata {
            phase = .fetchingMetadata
        } else if done {
            phase = .seeding
        } else {
            phase = .downloading
        }
        set(\.phase, phase)

        speedHistory.append(SpeedSample(down: Int(s.downloadRate), up: Int(s.uploadRate)))
        if speedHistory.count > 120 { speedHistory.removeFirst(speedHistory.count - 120) }
    }
}

struct SpeedSample: Hashable {
    var down: Int
    var up: Int
}

struct TorrentFile: Identifiable, Hashable {
    var index: Int
    var path: String
    var size: Int64
    var downloaded: Int64
    var priority: Int

    var id: Int { index }
    var name: String { (path as NSString).lastPathComponent }
    var kind: FileKind { FileKind(path: path) }
    var progress: Double { size > 0 ? min(1, Double(downloaded) / Double(size)) : 1 }
    var isWanted: Bool { priority > 0 }
    var isComplete: Bool { downloaded >= size }

    init(_ f: KTFileEntry) {
        index = Int(f.index)
        path = f.path
        size = f.size
        downloaded = f.downloaded
        priority = Int(f.priority)
    }
}

struct TorrentPeer: Identifiable, Hashable {
    var id: String { address }
    var address: String
    var client: String
    var progress: Double
    var downloadRate: Int
    var uploadRate: Int
    var isSeed: Bool
}

struct TorrentTracker: Identifiable, Hashable {
    var id: String { url }
    var url: String
    var message: String
    var tier: Int
    var seeds: Int
    var leechers: Int
    var working: Bool
    var updating: Bool

    var host: String { URL(string: url)?.host ?? url }
}
