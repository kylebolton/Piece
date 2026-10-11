import Foundation

/// Fake in-progress transfers for screenshots: launch with `PIECE_DEMO=1`. The titles are open-licensed films.
enum DemoTorrents {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PIECE_DEMO"] != nil }

    private struct Entry {
        var name: String
        var gb: Double
        var progress: Double
        var phase: TorrentPhase
        var rateMB: Double
        var upKB: Double = 0
        var peers: Int
        var seeds: Int
        var addedMinutesAgo: Double
    }

    private static let entries: [Entry] = [
        Entry(name: "Sintel.2010.2160p.4K.Blender.Open.Movie.x265", gb: 6.8, progress: 0.64, phase: .downloading, rateMB: 11.4, upKB: 420, peers: 38, seeds: 112, addedMinutesAgo: 22),
        Entry(name: "Big.Buck.Bunny.2008.1080p.BluRay.x264", gb: 2.4, progress: 0.31, phase: .downloading, rateMB: 7.9, upKB: 180, peers: 24, seeds: 87, addedMinutesAgo: 9),
        Entry(name: "Tears.of.Steel.2012.1080p.WEB-DL.DDP5.1.x264", gb: 3.1, progress: 0.92, phase: .downloading, rateMB: 14.2, upKB: 640, peers: 51, seeds: 140, addedMinutesAgo: 41),
        Entry(name: "Cosmos.Laundromat.2015.1080p.Blender.Open.Movie", gb: 1.9, progress: 0.12, phase: .downloading, rateMB: 4.3, upKB: 60, peers: 12, seeds: 33, addedMinutesAgo: 3),
        Entry(name: "Elephants.Dream.2006.720p.HDRip.x264", gb: 0.9, progress: 0.58, phase: .paused, rateMB: 0, peers: 0, seeds: 0, addedMinutesAgo: 75),
        Entry(name: "Spring.2019.Blender.Open.Movie.1080p.x264", gb: 1.4, progress: 0, phase: .queued, rateMB: 0, peers: 0, seeds: 0, addedMinutesAgo: 1),
        Entry(name: "Nosferatu.1922.Restored.1080p.BluRay.x264", gb: 4.2, progress: 1, phase: .seeding, rateMB: 0, upKB: 1850, peers: 19, seeds: 0, addedMinutesAgo: 190),
        Entry(name: "Metropolis.1927.Restored.2160p.UHD.BluRay.x265", gb: 11.6, progress: 1, phase: .seeding, rateMB: 0, upKB: 920, peers: 11, seeds: 0, addedMinutesAgo: 320),
    ]

    @MainActor static func makeTorrents() -> [Torrent] {
        entries.enumerated().map { index, entry in
            let torrent = Torrent(id: String(format: "%040x", index + 1), name: entry.name)
            let size = Int64(entry.gb * 1_073_741_824)
            torrent.phase = entry.phase
            torrent.hasMetadata = true
            torrent.isComplete = entry.progress >= 1
            torrent.progress = entry.progress
            torrent.totalSize = size
            torrent.totalWanted = size
            torrent.totalWantedDone = Int64(Double(size) * entry.progress)
            torrent.totalDownloaded = torrent.totalWantedDone
            torrent.totalUploaded = Int64(Double(size) * (entry.phase == .seeding ? 1.6 : 0.05))
            torrent.downloadRate = Int(entry.rateMB * 1_048_576)
            torrent.uploadRate = Int(entry.upKB * 1024)
            torrent.peers = entry.peers
            torrent.seeds = entry.seeds
            torrent.pieceLength = 4_194_304
            torrent.pieceCount = Int(size / 4_194_304)
            torrent.dateAdded = Date().addingTimeInterval(-entry.addedMinutesAgo * 60)
            torrent.savePath = NSHomeDirectory() + "/Downloads"
            // A gently wobbling history so the speed graph has something to draw.
            torrent.speedHistory = (0..<120).map { i in
                let wave = 0.75 + 0.25 * sin(Double(i) / 9 + Double(index))
                return SpeedSample(down: Int(Double(torrent.downloadRate) * wave), up: Int(Double(torrent.uploadRate) * wave))
            }
            return torrent
        }
    }

    private static let films: [(title: String, gb: Double, seeders: Int, leechers: Int, daysAgo: Double, provider: String)] = [
        ("Night.of.the.Living.Dead.1968.Remastered.1080p.BluRay.x264", 2.9, 1840, 212, 12, "Search indexers"),
        ("Nosferatu.1922.Restored.1080p.BluRay.x264", 4.2, 962, 87, 40, "Search indexers"),
        ("Metropolis.1927.Restored.2160p.UHD.BluRay.x265", 11.6, 718, 64, 95, "Search indexers"),
        ("Big.Buck.Bunny.2008.1080p.BluRay.x264", 2.4, 540, 31, 300, "Internet Archive"),
        ("Sintel.2010.2160p.4K.Blender.Open.Movie.x265", 6.8, 433, 54, 210, "Search indexers"),
        ("A.Trip.to.the.Moon.1902.Hand-Colored.1080p", 0.8, 291, 18, 520, "Internet Archive"),
        ("Tears.of.Steel.2012.1080p.WEB-DL.DDP5.1.x264", 3.1, 176, 22, 150, "Search indexers"),
        ("Charade.1963.1080p.BluRay.FLAC.x264", 7.4, 88, 9, 700, "Search indexers"),
    ]

    static func searchResults(for query: String) -> [SearchResult] {
        films.enumerated().map { index, film in
            var result = SearchResult(title: film.title, provider: film.provider)
            result.infoHash = String(format: "%040x", 0xA00 + index)
            result.magnet = "magnet:?xt=urn:btih:\(result.infoHash!)"
            result.size = Int64(film.gb * 1_073_741_824)
            result.seeders = film.seeders
            result.leechers = film.leechers
            result.date = Date().addingTimeInterval(-film.daysAgo * 86_400)
            return result
        }
    }
}
