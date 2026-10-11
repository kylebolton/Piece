import Foundation

enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Runs a helper to completion off the main thread.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 600) async -> Output? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: data,
                                                      stderr: String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }
}

/// What ffprobe reports about a media file.
struct MediaProbe {
    struct Stream: Hashable {
        enum Kind: String { case video, audio, subtitle, other }
        var index: Int
        var kind: Kind
        var codec: String
        var language: String?
        var title: String?
        var width: Int?
        var height: Int?
        var channels: Int?
        var isDefault: Bool
        var isAttachedPicture: Bool
    }

    var duration: Double
    var streams: [Stream]
    var tags: [String: String]

    var video: Stream? { streams.first { $0.kind == .video && !$0.isAttachedPicture } }
    var audio: [Stream] { streams.filter { $0.kind == .audio } }
    var subtitles: [Stream] { streams.filter { $0.kind == .subtitle } }

    /// Subtitle codecs that are text and can be converted to cues.
    static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"]

    /// Video codecs AVPlayer can decode from fragmented MP4 without re-encoding.
    static let copyableVideoCodecs: Set<String> = ["h264", "hevc"]
    static let copyableAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    static func probe(_ input: String) async -> MediaProbe? {
        guard let ffprobe = AppPaths.helper("ffprobe") else { return nil }
        let args = ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", input]
        guard let output = await ProcessRunner.run(ffprobe, args, timeout: 180), output.status == 0 else { return nil }
        return parse(output.stdout)
    }

    static func parse(_ data: Data) -> MediaProbe? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let format = root["format"] as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        for (key, value) in format["tags"] as? [String: Any] ?? [:] {
            tags[key.lowercased()] = "\(value)"
        }
        let streams = (root["streams"] as? [[String: Any]] ?? []).map { s -> Stream in
            let streamTags = s["tags"] as? [String: Any] ?? [:]
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            let language = (streamTags["language"] ?? streamTags["LANGUAGE"]) as? String
            return Stream(
                index: s["index"] as? Int ?? 0,
                kind: Stream.Kind(rawValue: s["codec_type"] as? String ?? "") ?? .other,
                codec: (s["codec_name"] as? String ?? "").lowercased(),
                language: language == "und" ? nil : language,
                title: (streamTags["title"] ?? streamTags["TITLE"]) as? String,
                width: s["width"] as? Int,
                height: s["height"] as? Int,
                channels: s["channels"] as? Int,
                isDefault: (disposition["default"] as? Int ?? 0) == 1,
                isAttachedPicture: (disposition["attached_pic"] as? Int ?? 0) == 1
            )
        }
        // Ogg and some FLAC files keep their tags on the audio stream rather than the container.
        for s in root["streams"] as? [[String: Any]] ?? [] where s["codec_type"] as? String == "audio" {
            for (key, value) in s["tags"] as? [String: Any] ?? [:] where tags[key.lowercased()] == nil {
                tags[key.lowercased()] = "\(value)"
            }
        }
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        return MediaProbe(duration: duration, streams: streams, tags: tags)
    }
}

/// An ffmpeg process turning any input into HLS that AVPlayer and AirPlay receivers can play.
final class HLSSession {
    let id = UUID().uuidString
    let directory: URL
    private let server: StreamServer
    private var process: Process?
    private(set) var log = ""

    init(server: StreamServer) {
        self.server = server
        directory = AppPaths.temporary.appendingPathComponent("hls-\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server.registerHLS(id: id, directory: directory)
    }

    deinit { stop() }

    var masterURL: URL { server.hlsURL(sessionID: id, file: "master.m3u8") }

    /// Builds the ffmpeg arguments: copy streams when AVPlayer can play them, re-encode otherwise.
    static func arguments(input: String, probe: MediaProbe?, audioStream: Int?, startTime: Double,
                          outputDirectory: String) -> [String] {
        var args = ["-hide_banner", "-loglevel", "warning", "-nostdin"]
        if startTime > 0 { args += ["-ss", String(format: "%.3f", startTime)] }
        args += ["-fflags", "+genpts", "-i", input]

        let video = probe?.video
        let audio = probe?.audio.first { $0.index == audioStream } ?? probe?.audio.first { $0.isDefault } ?? probe?.audio.first

        if let video {
            args += ["-map", "0:\(video.index)"]
            if MediaProbe.copyableVideoCodecs.contains(video.codec) {
                args += ["-c:v", "copy"]
                if video.codec == "hevc" { args += ["-tag:v", "hvc1"] }
            } else {
                args += ["-c:v", "h264_videotoolbox", "-b:v", (video.height ?? 720) > 1080 ? "16M" : "8M",
                         "-pix_fmt", "yuv420p", "-g", "96"]
            }
        } else if probe == nil {
            args += ["-map", "0:v:0?", "-c:v", "copy"]
        } else {
            args += ["-vn"]
        }

        if let audio {
            args += ["-map", "0:\(audio.index)"]
            if MediaProbe.copyableAudioCodecs.contains(audio.codec), audio.codec != "alac" {
                args += ["-c:a", "copy"]
            } else {
                args += ["-c:a", "aac", "-b:a", (audio.channels ?? 2) > 2 ? "384k" : "192k"]
                if (audio.channels ?? 2) > 6 { args += ["-ac", "6"] }
            }
        } else if probe == nil {
            args += ["-map", "0:a:0?", "-c:a", "aac", "-b:a", "192k"]
        }

        args += [
            "-sn", "-dn", "-map_metadata", "-1", "-max_muxing_queue_size", "4096",
            "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "event",
            "-hls_segment_type", "fmp4", "-hls_flags", "independent_segments",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", "\(outputDirectory)/seg%05d.m4s",
            "\(outputDirectory)/media.m3u8",
        ]
        return args
    }

    /// A master playlist is what lets a subtitle track ride along to AirPlay receivers.
    static func masterPlaylist(subtitleName: String?, language: String?) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        if let subtitleName {
            let lang = language ?? "en"
            lines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(subtitleName)\",LANGUAGE=\"\(lang)\",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI=\"subs.m3u8\"")
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES=\"subs\"")
        } else {
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=8000000")
        }
        lines.append("media.m3u8")
        return lines.joined(separator: "\n") + "\n"
    }

    static func subtitlePlaylist(duration: Double) -> String {
        let length = max(1, Int(duration.rounded(.up)))
        return """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(length)
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:\(length).0,
        subs.vtt
        #EXT-X-ENDLIST

        """
    }

    func start(input: String, probe: MediaProbe?, audioStream: Int? = nil, startTime: Double = 0,
               subtitles: (name: String, language: String?, cues: [SubtitleCue])? = nil) -> Bool {
        guard let ffmpeg = AppPaths.helper("ffmpeg") else { return false }

        if let subtitles, !subtitles.cues.isEmpty {
            let shifted = subtitles.cues.compactMap { cue -> SubtitleCue? in
                guard cue.end > startTime else { return nil }
                return SubtitleCue(start: max(0, cue.start - startTime), end: cue.end - startTime, text: cue.text)
            }
            let duration = max(probe?.duration ?? 0, shifted.last?.end ?? 0)
            try? SubtitleParser.webVTT(from: shifted, hlsTimestampMap: true)
                .write(to: directory.appendingPathComponent("subs.vtt"), atomically: true, encoding: .utf8)
            try? Self.subtitlePlaylist(duration: duration)
                .write(to: directory.appendingPathComponent("subs.m3u8"), atomically: true, encoding: .utf8)
            try? Self.masterPlaylist(subtitleName: subtitles.name, language: subtitles.language)
                .write(to: directory.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        } else {
            try? Self.masterPlaylist(subtitleName: nil, language: nil)
                .write(to: directory.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
        }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = Self.arguments(input: input, probe: probe, audioStream: audioStream,
                                           startTime: startTime, outputDirectory: directory.path)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.log = String(((self?.log ?? "") + text).suffix(4000)) }
        }
        do { try process.run() } catch { return false }
        self.process = process
        return true
    }

    var isRunning: Bool { process?.isRunning ?? false }

    /// Non-zero when ffmpeg stopped on its own with an error (nil while running or after a clean finish).
    var failureStatus: Int32? {
        guard let process, !process.isRunning, process.terminationReason == .exit || process.terminationReason == .uncaughtSignal else { return nil }
        return process.terminationStatus == 0 ? nil : process.terminationStatus
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        server.unregisterHLS(id: id)
        try? FileManager.default.removeItem(at: directory)
    }
}
