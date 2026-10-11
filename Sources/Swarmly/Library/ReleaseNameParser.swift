import Foundation

struct ParsedRelease: Equatable {
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    var resolution: String?
    var source: String?
    var group: String?

    var isEpisode: Bool { season != nil || episode != nil }
}

/// Pulls a clean title, year and episode numbers out of scene-style release names such as
/// "The.Matrix.1999.1080p.BluRay.x264-GROUP" or "Show.Name.S02E05.720p.WEB-DL".
enum ReleaseNameParser {
    private static let qualityTokens: Set<String> = [
        "2160p", "1080p", "1080i", "720p", "576p", "480p", "360p", "4k", "uhd", "hd", "sd", "hdr", "hdr10", "dv", "sdr",
        "bluray", "blu-ray", "bdrip", "brrip", "bdremux", "remux", "webrip", "web-dl", "webdl", "web", "hdtv", "pdtv",
        "dvdrip", "dvd", "dvdscr", "hdrip", "cam", "hdcam", "ts", "telesync", "screener", "vhsrip",
        "x264", "x265", "h264", "h265", "h.264", "h.265", "hevc", "avc", "xvid", "divx", "av1", "10bit", "8bit",
        "aac", "ac3", "eac3", "dts", "dts-hd", "truehd", "atmos", "flac", "mp3", "dd5", "ddp5", "dd", "ddp",
        "proper", "repack", "extended", "unrated", "limited", "internal", "remastered", "uncut", "imax", "complete",
        "multi", "dubbed", "subbed", "dual", "nf", "amzn", "dsnp", "hmax", "atvp", "hulu",
    ]

    private static let resolutions = ["2160p", "1080p", "1080i", "720p", "576p", "480p", "360p"]
    private static let sources: [(String, String)] = [
        ("remux", "Remux"), ("bluray", "Blu-ray"), ("blu-ray", "Blu-ray"), ("bdrip", "Blu-ray"), ("brrip", "Blu-ray"),
        ("web-dl", "WEB"), ("webdl", "WEB"), ("webrip", "WEB"), ("web", "WEB"), ("hdtv", "HDTV"),
        ("dvdrip", "DVD"), ("dvd", "DVD"), ("hdrip", "HDRip"), ("cam", "Cam"), ("hdcam", "Cam"),
    ]

    private static let episodePatterns: [NSRegularExpression] = [
        // S01E02, s1e2, S01.E02, S01E02E03
        try! NSRegularExpression(pattern: #"(?i)\bs(\d{1,2})[ ._-]?e(\d{1,3})"#),
        // 1x02
        try! NSRegularExpression(pattern: #"(?i)\b(\d{1,2})x(\d{2,3})\b"#),
        // Season 1 Episode 2
        try! NSRegularExpression(pattern: #"(?i)\bseason[ ._-]?(\d{1,2})[ ._-]+episode[ ._-]?(\d{1,3})"#),
    ]
    private static let seasonOnly = try! NSRegularExpression(pattern: #"(?i)\b(?:s|season[ ._-]?)(\d{1,2})\b"#)
    private static let yearPattern = try! NSRegularExpression(pattern: #"\b(19\d{2}|20\d{2})\b"#)

    static func parse(_ rawName: String) -> ParsedRelease {
        var name = rawName
        let ext = (name as NSString).pathExtension.lowercased()
        if FileKind.videoExtensions.contains(ext) || FileKind.audioExtensions.contains(ext)
            || FileKind.subtitleExtensions.contains(ext) || ext == "torrent" {
            name = (name as NSString).deletingPathExtension
        }

        // Leading "[Group]" tags and "www.site.com - " prefixes.
        name = name.replacingOccurrences(of: #"^(\[[^\]]*\]\s*)+"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)^www\.[a-z0-9-]+\.[a-z]{2,6}\s*[-–]\s*"#, with: "", options: .regularExpression)

        var group: String?
        if let match = name.range(of: #"-([A-Za-z0-9]{2,12})$"#, options: .regularExpression) {
            let candidate = String(name[match].dropFirst())
            if !qualityTokens.contains(candidate.lowercased()), Int(candidate) == nil { group = candidate }
        }

        let spaced = name.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        let ns = spaced as NSString
        let full = NSRange(location: 0, length: ns.length)
        var cut = ns.length

        var season: Int?, episode: Int?
        for pattern in episodePatterns {
            if let m = pattern.firstMatch(in: spaced, range: full) {
                season = Int(ns.substring(with: m.range(at: 1)))
                episode = Int(ns.substring(with: m.range(at: 2)))
                cut = min(cut, m.range.location)
                break
            }
        }
        if season == nil, let m = seasonOnly.firstMatch(in: spaced, range: full), m.range.location > 0 {
            season = Int(ns.substring(with: m.range(at: 1)))
            cut = min(cut, m.range.location)
        }

        // First quality token marks the end of the title.
        var resolution: String?, source: String?
        var qualityStart = ns.length
        var location = 0
        for word in spaced.components(separatedBy: " ") {
            let lower = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
            if qualityTokens.contains(lower) || lower.range(of: #"^\d{3,4}[pi]$"#, options: .regularExpression) != nil {
                // "TS", "DV", "HD", "SD", "WEB", "CAM", "DD" are too short to trust at the very start of a name.
                if location > 0 { qualityStart = min(qualityStart, location) }
                if resolution == nil, resolutions.contains(lower) { resolution = lower }
                if lower == "4k" || lower == "uhd", resolution == nil { resolution = "2160p" }
                if source == nil, let s = sources.first(where: { $0.0 == lower }) { source = s.1 }
            }
            location += (word as NSString).length + 1
        }
        cut = min(cut, qualityStart)

        // The release year is the last year before the quality tags, unless it's the first word of the title.
        var year: Int?
        let years = yearPattern.matches(in: spaced, range: full).filter { $0.range.location < min(qualityStart, ns.length) }
        if let m = years.last(where: { $0.range.location > 0 && $0.range.location <= cut })
            ?? years.last(where: { $0.range.location > 0 }) {
            let value = Int(ns.substring(with: m.range)) ?? 0
            if value <= Calendar.current.component(.year, from: Date()) + 1 {
                year = value
                cut = min(cut, m.range.location)
            }
        }

        var title = ns.substring(to: max(0, min(cut, ns.length)))
        title = title.replacingOccurrences(of: #"[\[\(\{][^\]\)\}]*$"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -–"))
        if title.isEmpty {
            title = spaced.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        return ParsedRelease(title: title, year: year, season: season, episode: episode,
                             resolution: resolution, source: source, group: group)
    }
}
