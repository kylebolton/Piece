import Foundation

struct SubtitleCue: Hashable {
    var start: Double
    var end: Double
    var text: String
}

struct SubtitleTrack: Identifiable, Hashable {
    enum Source: Hashable {
        case file(URL)
        case torrentFile(hash: String, index: Int, absolutePath: String, size: Int64)
        case embedded(streamIndex: Int)
        case online(fileID: Int)
    }

    var id: String
    var name: String
    var language: String?
    var detail: String?
    var source: Source

    var menuTitle: String {
        var title = language.flatMap(SubtitleLanguage.name(for:)) ?? name
        if let detail, !detail.isEmpty { title += " — \(detail)" }
        return title
    }
}

enum SubtitleLanguage {
    /// (ISO 639-1, ISO 639-2 variants, English name)
    private static let table: [(String, [String], String)] = [
        ("en", ["eng"], "English"), ("es", ["spa", "esp"], "Spanish"), ("fr", ["fre", "fra"], "French"),
        ("de", ["ger", "deu"], "German"), ("it", ["ita"], "Italian"), ("pt", ["por", "pob"], "Portuguese"),
        ("nl", ["dut", "nld"], "Dutch"), ("sv", ["swe"], "Swedish"), ("no", ["nor", "nob"], "Norwegian"),
        ("da", ["dan"], "Danish"), ("fi", ["fin"], "Finnish"), ("pl", ["pol"], "Polish"),
        ("ru", ["rus"], "Russian"), ("uk", ["ukr"], "Ukrainian"), ("cs", ["cze", "ces"], "Czech"),
        ("hu", ["hun"], "Hungarian"), ("ro", ["rum", "ron"], "Romanian"), ("el", ["gre", "ell"], "Greek"),
        ("tr", ["tur"], "Turkish"), ("ar", ["ara"], "Arabic"), ("he", ["heb"], "Hebrew"),
        ("hi", ["hin"], "Hindi"), ("ja", ["jpn"], "Japanese"), ("ko", ["kor"], "Korean"),
        ("zh", ["chi", "zho", "chs", "cht"], "Chinese"), ("vi", ["vie"], "Vietnamese"), ("th", ["tha"], "Thai"),
        ("id", ["ind"], "Indonesian"), ("bg", ["bul"], "Bulgarian"), ("hr", ["hrv"], "Croatian"),
        ("sr", ["srp"], "Serbian"), ("sk", ["slo", "slk"], "Slovak"), ("sl", ["slv"], "Slovenian"),
    ]

    static var all: [(code: String, name: String)] { table.map { ($0.0, $0.2) } }

    /// Normalises "eng", "EN", "English" or "en-US" to "en".
    static func code(for token: String) -> String? {
        let t = token.lowercased().split(separator: "-").first.map(String.init) ?? token.lowercased()
        for (code, alternates, name) in table where t == code || alternates.contains(t) || t == name.lowercased() {
            return code
        }
        return nil
    }

    static func name(for code: String) -> String? {
        guard let normalised = Self.code(for: code) else { return nil }
        return table.first { $0.0 == normalised }?.2
    }

    /// Guesses the language from a subtitle filename such as "Movie.2019.eng.srt" or "Subs/English.srt".
    static func guess(fromFilename filename: String) -> String? {
        let base = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        let tokens = base.split(whereSeparator: { ".-_ []()".contains($0) }).map(String.init)
        for token in tokens.reversed() where token.count >= 2 {
            // Two-letter tokens are only trusted at the end ("movie.en.srt"), not mid-title.
            if token.count == 2, token != tokens.last { continue }
            if let code = code(for: token) { return code }
        }
        return nil
    }
}

enum SubtitleParser {
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted,
                                               usedLossyConversion: nil)
        if encoding != 0, let converted { return converted as String }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String, fileExtension: String? = nil) -> [SubtitleCue] {
        let ext = fileExtension?.lowercased()
        let cues: [SubtitleCue]
        if ext == "ass" || ext == "ssa" || text.contains("[Script Info]") {
            cues = parseASS(text)
        } else {
            cues = parseSRT(text)
        }
        return cues.filter { !$0.text.isEmpty && $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    /// Handles both SubRip and WebVTT, which share the "start --> end" cue format.
    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        var lines = normalised.components(separatedBy: "\n")[...]
        while let index = lines.firstIndex(where: { $0.contains("-->") }) {
            let timing = lines[index].components(separatedBy: "-->")
            lines = lines[(index + 1)...]
            var body: [String] = []
            while let line = lines.first, !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.contains("-->") {
                body.append(line)
                lines = lines.dropFirst()
            }
            // A cue number belonging to the next cue can get swallowed when blank lines are missing.
            if lines.first?.contains("-->") == true, let last = body.last, Int(last.trimmingCharacters(in: .whitespaces)) != nil {
                body.removeLast()
            }
            guard timing.count == 2, let start = time(timing[0]),
                  let end = time(timing[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: clean(body.joined(separator: "\n"))))
        }
        return cues
    }

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var inEvents = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEvents = line.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.lowercased().hasPrefix("dialogue:") {
                let fields = line.dropFirst(9).split(separator: ",", maxSplits: max(0, format.count - 1),
                                                     omittingEmptySubsequences: false).map(String.init)
                guard fields.count == format.count,
                      let s = format.firstIndex(of: "start"), let e = format.firstIndex(of: "end"),
                      let start = time(fields[s]), let end = time(fields[e]) else { continue }
                var body = fields[format.count - 1]
                body = body.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                body = body.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\h", with: " ")
                cues.append(SubtitleCue(start: start, end: end, text: clean(body)))
            }
        }
        return cues
    }

    /// "01:02:03,456", "02:03.456" or "1:02:03.45" → seconds.
    static func time(_ string: String) -> Double? {
        let parts = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    static func webVTT(from cues: [SubtitleCue], hlsTimestampMap: Bool = false) -> String {
        var out = "WEBVTT\n"
        if hlsTimestampMap { out += "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n" }
        out += "\n"
        for cue in cues {
            out += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n\n"
        }
        return out
    }

    /// The cue to show at `time`, using binary search since cues are sorted by start.
    static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        var low = 0, high = cues.count - 1
        var candidate: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard var index = candidate else { return nil }
        // Overlapping cues: step back to find one still on screen.
        var steps = 0
        while index >= 0, steps < 4 {
            if cues[index].end > time { return cues[index] }
            index -= 1
            steps += 1
        }
        return nil
    }
}

enum SubtitleFinder {
    /// Subtitle files that belong to `videoPath`: same base name, or sitting in a Subs folder beside it.
    static func matches(forVideo videoPath: String, among paths: [String]) -> [String] {
        let videoDir = (videoPath as NSString).deletingLastPathComponent
        let videoBase = ((videoPath as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let videosInDir = paths.filter {
            FileKind(path: $0) == .video && ($0 as NSString).deletingLastPathComponent == videoDir
        }.count

        return paths.filter { path in
            guard FileKind(path: path) == .subtitle, (path as NSString).pathExtension.lowercased() != "sub" else { return false }
            let dir = (path as NSString).deletingLastPathComponent
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
            if dir == videoDir {
                return base.hasPrefix(videoBase) || videosInDir <= 1
            }
            // "Subs/…" or "Subs/<video name>/…" next to the video.
            let relative = videoDir.isEmpty ? dir : (dir.hasPrefix(videoDir + "/") ? String(dir.dropFirst(videoDir.count + 1)) : nil)
            guard let relative else { return false }
            let components = relative.lowercased().split(separator: "/").map(String.init)
            guard let first = components.first, ["subs", "subtitles", "sub"].contains(first) else { return false }
            if components.count > 1 { return components[1] == videoBase }
            return base.hasPrefix(videoBase) || videosInDir <= 1
        }
    }
}
