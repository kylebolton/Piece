import Foundation

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, value))
    }

    static func rate(_ bytesPerSecond: Int) -> String {
        bytesPerSecond <= 0 ? "0 KB/s" : "\(bytes(Int64(bytesPerSecond)))/s"
    }

    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return clamped >= 0.9995 ? "100%" : String(format: "%.1f%%", clamped * 100)
    }

    /// "3 min", "2 h 14 min", "4 days"
    static func eta(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds)
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 {
            let m = (s % 3600) / 60
            return m == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(m) min"
        }
        let days = s / 86_400
        return days > 365 ? "over a year" : "\(days) day\(days == 1 ? "" : "s")"
    }

    /// "1:02:03" or "4:05"
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "1 h 42 min"
    static func runtime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "" }
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    static func ratio(uploaded: Int64, downloaded: Int64) -> String {
        guard downloaded > 0 else { return uploaded > 0 ? "∞" : "0.00" }
        return String(format: "%.2f", Double(uploaded) / Double(downloaded))
    }

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

enum FileKind {
    case video, audio, subtitle, image, archive, document, other

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp", "divx", "vob",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "oga", "opus", "wma", "alac", "ape", "wv", "m4b",
    ]
    static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "dmg", "pkg"]
    static let documentExtensions: Set<String> = ["pdf", "epub", "mobi", "txt", "nfo", "md", "doc", "docx", "rtf", "cbz", "cbr"]

    /// Containers and codecs AVPlayer handles without help from ffmpeg.
    static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "m4b"]

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { self = .video }
        else if Self.audioExtensions.contains(ext) { self = .audio }
        else if Self.subtitleExtensions.contains(ext) { self = .subtitle }
        else if Self.imageExtensions.contains(ext) { self = .image }
        else if Self.archiveExtensions.contains(ext) { self = .archive }
        else if Self.documentExtensions.contains(ext) { self = .document }
        else { self = .other }
    }

    var isPlayable: Bool { self == .video || self == .audio }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .subtitle: "captions.bubble"
        case .image: "photo"
        case .archive: "archivebox"
        case .document: "doc.text"
        case .other: "doc"
        }
    }
}

enum AppPaths {
    /// True when the app is only running as the host for unit tests.
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static let support: URL = {
        LegacyMigration.run
        // Tests get a throwaway folder so they never touch real downloads or settings.
        let base = isTesting || DemoTorrents.isEnabled
            ? FileManager.default.temporaryDirectory.appendingPathComponent("PieceTests-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Piece", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func directory(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var artwork: URL { directory("Artwork") }
    static var subtitles: URL { directory("Subtitles") }

    static let temporary: URL = {
        // Per-process, so a second copy of the app can't delete streams this one is serving.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Piece-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Bundled helper (ffmpeg / ffprobe), falling back to a Homebrew install during development.
    static func helper(_ name: String) -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
