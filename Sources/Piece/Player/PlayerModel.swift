import AVFoundation
import Foundation

struct PlaybackItem: Equatable {
    enum Origin: Equatable {
        case torrent(hash: String, fileIndex: Int, relativePath: String, absolutePath: String, size: Int64)
        case file(URL)
    }

    var title: String
    var detail: String?
    var origin: Origin
    var libraryID: UUID?
    var startPosition: Double = 0

    var absolutePath: String {
        switch origin {
        case .torrent(_, _, _, let path, _): path
        case .file(let url): url.path
        }
    }

    var isAudioOnly: Bool { FileKind(path: absolutePath) == .audio }
}

/// Drives playback for the player window: picks direct play or the ffmpeg/HLS path,
/// keeps subtitles in sync and hands everything to AirPlay when a receiver is chosen.
@MainActor
@Observable
final class PlayerModel {
    enum Status: Equatable {
        case idle
        case preparing(String)
        case ready
        case failed(String)
    }

    private enum Mode: Equatable {
        case direct
        case hls(withSubtitles: Bool)
    }

    @ObservationIgnored let player = AVPlayer()

    private(set) var item: PlaybackItem?
    private(set) var status: Status = .idle
    private(set) var isBuffering = false
    private(set) var bufferingDetail = ""
    private(set) var isExternal = false
    private(set) var isConverting = false
    private(set) var isPlaying = false
    /// Playback speed chosen by the viewer (1 = normal).
    private(set) var rate: Float = 1
    /// Set while a resumed position is being offered back ("Resumed at 12:34 — Start Over").
    private(set) var resumedFrom: Double?
    /// A non-fatal problem worth showing, such as the converter stopping mid-stream.
    private(set) var notice: String?
    /// True while the player window is on screen; AirPlay keeps going without it.
    var isWindowVisible = false
    /// Called when a library item plays to the end, so the app can queue the next episode.
    @ObservationIgnored var onFinished: ((UUID) -> Void)?

    private(set) var subtitleTracks: [SubtitleTrack] = []
    private(set) var selectedSubtitleID: String?
    private(set) var cueText: String?
    /// The track being fetched or parsed right now; the previous subtitles stay on screen until it's ready.
    private(set) var loadingSubtitleID: String?
    /// Why a track couldn't be loaded, by track id.
    private(set) var subtitleFailures: [String: String] = [:]
    private(set) var onlineResults: [OnlineSubtitle] = []
    private(set) var onlineSearch: OnlineSearchState = .idle
    var isSearchingOnline: Bool { onlineSearch == .searching }
    var subtitleDelay: Double = 0

    enum OnlineSearchState: Equatable {
        case idle
        case searching
        /// Finished; `query` is the title that was searched for.
        case finished(query: String)
        case failed(String)
    }

    private(set) var audioStreams: [MediaProbe.Stream] = []
    private(set) var selectedAudioStream: Int?

    @ObservationIgnored private let server: StreamServer
    @ObservationIgnored private let torrents: TorrentStore
    @ObservationIgnored private let library: LibraryStore

    @ObservationIgnored private var mode: Mode = .direct
    @ObservationIgnored private var hls: HLSSession?
    @ObservationIgnored private var probe: MediaProbe?
    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var generation = 0
    /// Identifies the latest online search, so a slow earlier one can't overwrite its results.
    @ObservationIgnored private var searchToken = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedPosition: Double = 0
    /// Where in the film the current stream starts. Converted streams are started at the resume or seek
    /// position rather than converting everything before it, so the player's own clock runs behind by this much.
    @ObservationIgnored private var timeOffset: Double = 0
    @ObservationIgnored private var openSerial = 0
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var resumeToastTask: Task<Void, Never>?

    init(server: StreamServer, torrents: TorrentStore, library: LibraryStore) {
        self.server = server
        self.torrents = torrents
        self.library = library
        player.allowsExternalPlayback = true

        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                self?.isBuffering = waiting
                self?.isPlaying = playing
            }
        })
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in self?.externalPlaybackChanged(active) }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    var selectedSubtitle: SubtitleTrack? { subtitleTracks.first { $0.id == selectedSubtitleID } }
    /// Position in the film, whichever point the stream started from.
    var currentTime: Double {
        let t = player.currentTime().seconds
        return (t.isFinite ? t : 0) + timeOffset
    }

    /// Length of the film when known, from the stream or from ffprobe.
    private var mediaDuration: Double {
        let streamed = player.currentItem?.duration.seconds ?? 0
        if streamed.isFinite, streamed > 0 { return streamed + timeOffset }
        return probe?.duration ?? 0
    }

    // MARK: - Starting and stopping

    func play(_ newItem: PlaybackItem) {
        // Not `stop()`: the transfer hold would close in on the old torrent only to let it go again.
        tearDown()
        var newItem = newItem
        if newItem.libraryID == nil {
            newItem.libraryID = library.items.first { $0.path == newItem.absolutePath }?.id
        }
        if newItem.startPosition == 0, let id = newItem.libraryID, let saved = library.item(id),
           !saved.isWatched, saved.playPosition > 30, saved.duration - saved.playPosition > 60 {
            newItem.startPosition = saved.playPosition
        }
        item = newItem
        status = .preparing("Preparing…")
        showResumeToast(newItem.startPosition > 1 ? newItem.startPosition : nil)

        if case .torrent(let hash, _, _, _, _) = newItem.origin {
            torrents.policy.playingHash = hash
        } else {
            torrents.policy.playingHash = nil
        }
        if case .torrent(let hash, let index, _, _, let size) = newItem.origin {
            if let torrent = torrents.torrent(hash) {
                if torrent.phase == .paused { torrents.resume(torrent) }
                // A queued transfer never gets pieces until its turn comes; playing it can't wait for that.
                if torrent.phase == .queued { torrents.forceStart(torrent) }
            }
            // Containers keep their index at the start or the end; fetch both before anything else.
            server.session.prioritizeTorrent(hash, file: Int32(index), offset: 0, window: 12 * 1024 * 1024)
            server.session.prioritizeTorrent(hash, file: Int32(index), offset: max(0, size - 4 * 1024 * 1024), window: 4 * 1024 * 1024)
        }

        startStatusUpdates()
        let generation = generation
        Task {
            await open(at: newItem.startPosition, forceHLS: false, withSubtitles: false)
            guard generation == self.generation else { return }
            await loadSubtitleTracks()
        }
    }

    func stop() {
        tearDown()
        torrents.policy.playingHash = nil
    }

    private func tearDown() {
        savePosition(force: true)
        generation += 1
        statusTask?.cancel()
        statusTask = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        hls?.stop()
        hls = nil
        if case .torrent(let hash, _, _, _, _) = item?.origin {
            server.session.clearDeadlines(forTorrent: hash)
        }
        item = nil
        status = .idle
        probe = nil
        cues = []
        cueText = nil
        subtitleTracks = []
        selectedSubtitleID = nil
        loadingSubtitleID = nil
        subtitleFailures = [:]
        onlineResults = []
        onlineSearch = .idle
        searchToken += 1
        audioStreams = []
        selectedAudioStream = nil
        subtitleDelay = 0
        isConverting = false
        timeOffset = 0
        isBuffering = false
        isPlaying = false
        notice = nil
        resumedFrom = nil
        resumeToastTask?.cancel()
        endActivity()
    }

    // MARK: - Transport

    func skip(by seconds: Double) {
        guard item != nil, status == .ready else { return }
        let duration = mediaDuration
        var target = max(0, currentTime + seconds)
        if duration.isFinite, duration > 0 { target = min(target, max(0, duration - 1)) }
        // Before the start of a converted stream: convert again from there.
        if target < timeOffset { return reopen(at: target, forceHLS: true, withSubtitles: mode == .hls(withSubtitles: true)) }
        player.seek(to: CMTime(seconds: target - timeOffset, preferredTimescale: 600), toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
    }

    func setRate(_ newRate: Float) {
        rate = min(max(newRate, 0.25), 3)
        player.defaultRate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    func stepRate(_ direction: Int) {
        let steps: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
        let index = steps.lastIndex { $0 <= rate + 0.001 } ?? 2
        setRate(steps[min(max(index + direction, 0), steps.count - 1)])
    }

    func togglePlayPause() {
        guard item != nil else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func startOver() {
        resumedFrom = nil
        if timeOffset > 0 { return reopen(at: 0, forceHLS: true, withSubtitles: mode == .hls(withSubtitles: true)) }
        player.seek(to: .zero)
    }

    func retry() {
        guard let item else { return }
        var again = item
        again.startPosition = max(again.startPosition, currentTime)
        play(again)
    }

    /// Cycles off → each subtitle track → off, for a keyboard shortcut.
    func cycleSubtitles() {
        guard !subtitleTracks.isEmpty else { return }
        let next: SubtitleTrack?
        if let index = subtitleTracks.firstIndex(where: { $0.id == selectedSubtitleID }) {
            next = index + 1 < subtitleTracks.count ? subtitleTracks[index + 1] : nil
        } else {
            next = subtitleTracks.first
        }
        Task { await select(subtitle: next) }
    }

    private func showResumeToast(_ position: Double?) {
        resumeToastTask?.cancel()
        resumedFrom = position
        guard position != nil else { return }
        resumeToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.resumedFrom = nil
        }
    }

    // MARK: - Keeping the Mac awake while casting

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Streaming to an AirPlay receiver")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private var isFileComplete: Bool {
        guard let item else { return false }
        switch item.origin {
        case .file: return true
        case .torrent(let hash, let index, _, _, let size):
            return server.session.contiguousBytes(inTorrent: hash, file: Int32(index), offset: 0) >= size
        }
    }

    /// Where ffmpeg and ffprobe should read from: the file itself once complete, the piece-aware server before that.
    private var toolInput: String {
        guard let item else { return "" }
        if case .torrent(let hash, let index, let relativePath, _, _) = item.origin, !isFileComplete {
            return server.torrentFileURL(hash: hash, fileIndex: index, name: (relativePath as NSString).lastPathComponent,
                                         loopback: true).absoluteString
        }
        return PartFile.resolve(item.absolutePath)
    }

    private func open(at position: Double, forceHLS: Bool, withSubtitles: Bool) async {
        guard let item else { return }
        let generation = generation
        openSerial += 1
        let serial = openSerial
        let ext = (item.absolutePath as NSString).pathExtension.lowercased()
        let wantsSubtitles = withSubtitles && !cues.isEmpty
        let useHLS = forceHLS || wantsSubtitles || !FileKind.nativeExtensions.contains(ext)

        hls?.stop()
        hls = nil
        let url: URL
        if useHLS {
            status = .preparing(isFileComplete ? "Preparing video…" : "Waiting for the first pieces…")
            if probe == nil {
                probe = await MediaProbe.probe(toolInput)
                guard generation == self.generation else { return }
                audioStreams = probe?.audio ?? []
            }
            // A newer open (say, AirPlay connecting while a reopen was in flight) supersedes this one.
            guard serial == openSerial else { return }
            let session = HLSSession(server: server)
            let subtitles = wantsSubtitles
                ? (name: selectedSubtitle?.menuTitle ?? "Subtitles", language: selectedSubtitle?.languageTag, cues: shiftedCues())
                : nil
            // Start converting at the position itself, so a resume deep into the film doesn't wait for
            // everything before it to be converted (or, mid-download, to arrive).
            let start = position > 1 ? position : 0
            guard session.start(input: toolInput, probe: probe, audioStream: selectedAudioStream, startTime: start,
                                subtitles: subtitles) else {
                status = .failed("The video converter (ffmpeg) isn't available.")
                return
            }
            timeOffset = start
            hls = session
            mode = .hls(withSubtitles: wantsSubtitles)
            isConverting = true
            url = session.masterURL
        } else {
            mode = .direct
            isConverting = false
            timeOffset = 0
            if case .torrent(let hash, let index, let relativePath, _, _) = item.origin, !isFileComplete {
                status = .preparing("Waiting for the first pieces…")
                url = server.torrentFileURL(hash: hash, fileIndex: index, name: (relativePath as NSString).lastPathComponent)
            } else {
                url = URL(fileURLWithPath: PartFile.resolve(item.absolutePath))
            }
        }

        let playerItem = AVPlayerItem(url: url)
        itemObservation = playerItem.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            let status = playerItem.status
            let message = playerItem.error?.localizedDescription
            Task { @MainActor in
                guard let self, generation == self.generation, self.player.currentItem === playerItem else { return }
                switch status {
                case .readyToPlay:
                    self.status = .ready
                    await self.selectLegibleOption(on: playerItem)
                case .failed:
                    if self.mode == .direct {
                        // The container was fine but a codec wasn't: let ffmpeg convert it.
                        await self.open(at: position, forceHLS: true, withSubtitles: withSubtitles)
                    } else {
                        let log = self.hls?.log.split(separator: "\n").last.map(String.init)
                        self.status = .failed(log ?? message ?? "This file couldn't be played.")
                    }
                default:
                    break
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
        player.replaceCurrentItem(with: playerItem)
        player.play()
        if position > 1, timeOffset == 0 { await seek(to: position, in: playerItem, generation: generation) }
    }

    /// Converted streams grow as ffmpeg works, so a resume position may not exist yet.
    private func seek(to position: Double, in playerItem: AVPlayerItem, generation: Int) async {
        for _ in 0..<120 {
            guard generation == self.generation, player.currentItem === playerItem else { return }
            if playerItem.status == .readyToPlay {
                if mode == .direct { break }
                let end = playerItem.seekableTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? 0
                if end >= position + 2 || hls?.isRunning == false { break }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard generation == self.generation, player.currentItem === playerItem else { return }
        await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
                          toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
    }

    private func reopen(forceHLS: Bool, withSubtitles: Bool) {
        reopen(at: currentTime, forceHLS: forceHLS, withSubtitles: withSubtitles)
    }

    private func reopen(at position: Double, forceHLS: Bool, withSubtitles: Bool) {
        Task { await open(at: position, forceHLS: forceHLS, withSubtitles: withSubtitles) }
    }

    // MARK: - Progress

    private func tick(_ streamTime: Double) {
        guard streamTime.isFinite else { return }
        let time = streamTime + timeOffset
        let text = cues.isEmpty ? nil : SubtitleParser.cue(at: time - subtitleDelay, in: cues)?.text
        if text != cueText { cueText = text }
        if abs(time - lastSavedPosition) > 5 { savePosition(force: false) }
    }

    private func savePosition(force: Bool) {
        guard let id = item?.libraryID, status == .ready else { return }
        let time = currentTime
        guard time > 0 else { return }
        lastSavedPosition = time
        let duration = mediaDuration
        library.update(id) {
            $0.playPosition = time
            $0.lastPlayed = Date()
            if duration.isFinite, duration > 0, $0.duration == 0 { $0.duration = duration }
            if $0.duration > 0, time / $0.duration > 0.92 { $0.isWatched = true }
        }
    }

    private func finished() {
        guard let id = item?.libraryID else { return }
        library.update(id) {
            $0.isWatched = true
            $0.playPosition = 0
            $0.playCount += 1
        }
        onFinished?(id)
    }

    private func startStatusUpdates() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if case .torrent(let hash, _, _, _, _) = self.item?.origin, let torrent = self.torrents.torrent(hash),
                   !torrent.isComplete {
                    self.bufferingDetail = "↓ \(Format.rate(torrent.downloadRate))  ·  \(torrent.peers) peer\(torrent.peers == 1 ? "" : "s")  ·  \(Format.percent(torrent.progress))"
                } else {
                    self.bufferingDetail = ""
                }
                if let hls = self.hls, !hls.isRunning, self.isConverting {
                    self.isConverting = false
                    if hls.failureStatus != nil, self.status == .ready {
                        self.notice = "The converter stopped early, so playback may end before the film does."
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - AirPlay

    private func externalPlaybackChanged(_ active: Bool) {
        isExternal = active
        if active { beginActivity() } else {
            endActivity()
            // The window was closed to leave the film playing on the TV; with the TV gone there's nothing left to show.
            if !isWindowVisible, item != nil {
                stop()
                return
            }
        }
        guard item != nil, status == .ready else { return }
        if active, !cues.isEmpty, mode != .hls(withSubtitles: true) {
            // The overlay can't reach the TV, so rebuild the stream with a subtitle track inside it.
            reopen(forceHLS: true, withSubtitles: true)
        } else if let playerItem = player.currentItem {
            Task { await selectLegibleOption(on: playerItem) }
        }
    }

    /// The in-stream subtitle track is only wanted on the AirPlay receiver; locally the overlay draws cues.
    private func selectLegibleOption(on playerItem: AVPlayerItem) async {
        guard case .hls(withSubtitles: true) = mode,
              let group = try? await playerItem.asset.loadMediaSelectionGroup(for: .legible) else { return }
        let language = selectedSubtitle?.languageTag
        let option = group.options.first { $0.extendedLanguageTag?.hasPrefix(language ?? "\u{0}") == true } ?? group.options.first
        playerItem.select(isExternal ? option : nil, in: group)
    }

    private func shiftedCues() -> [SubtitleCue] {
        guard subtitleDelay != 0 else { return cues }
        return cues.map { SubtitleCue(start: max(0, $0.start + subtitleDelay), end: max(0, $0.end + subtitleDelay), text: $0.text) }
    }

    // MARK: - Audio tracks

    func selectAudio(stream index: Int) {
        guard selectedAudioStream != index else { return }
        selectedAudioStream = index
        reopen(forceHLS: true, withSubtitles: isExternal)
    }

    // MARK: - Subtitles

    private func loadSubtitleTracks() async {
        guard let item, !item.isAudioOnly else { return }
        let generation = generation
        var tracks: [SubtitleTrack] = []

        switch item.origin {
        case .torrent(let hash, _, let relativePath, _, _):
            let files = await torrents.files(for: hash)
            let savePath = torrents.torrent(hash)?.savePath ?? ""
            for path in SubtitleFinder.matches(forVideo: relativePath, among: files.map(\.path)) {
                guard let file = files.first(where: { $0.path == path }) else { continue }
                tracks.append(SubtitleTrack(
                    id: "torrent:\(file.index)", name: file.name, language: SubtitleLanguage.guess(fromFilename: file.name),
                    detail: "From download",
                    source: .torrentFile(hash: hash, index: file.index,
                                         absolutePath: (savePath as NSString).appendingPathComponent(path), size: file.size)))
            }
        case .file(let url):
            let folder = url.deletingLastPathComponent()
            var relative: [String] = [url.lastPathComponent]
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])
            var visited = 0
            while let candidate = enumerator?.nextObject() as? URL, visited < 2000 {
                visited += 1
                if enumerator?.level ?? 0 > 2 { enumerator?.skipDescendants(); continue }
                if FileKind(path: candidate.path) == .subtitle || FileKind(path: candidate.path) == .video {
                    relative.append(String(candidate.path.dropFirst(folder.path.count + 1)))
                }
            }
            for path in SubtitleFinder.matches(forVideo: url.lastPathComponent, among: relative) {
                let name = (path as NSString).lastPathComponent
                tracks.append(SubtitleTrack(id: "file:\(path)", name: name, language: SubtitleLanguage.guess(fromFilename: name),
                                            detail: "File", source: .file(folder.appendingPathComponent(path))))
            }
        }

        if probe == nil {
            probe = await MediaProbe.probe(toolInput)
            guard generation == self.generation else { return }
            audioStreams = probe?.audio ?? []
        }
        for stream in probe?.subtitles ?? [] where MediaProbe.textSubtitleCodecs.contains(stream.codec) {
            tracks.append(SubtitleTrack(
                id: "embedded:\(stream.index)", name: stream.title ?? "Track \(stream.index)",
                language: SubtitleLanguage.identify(tag: stream.language, title: stream.title),
                detail: stream.title ?? "Embedded", source: .embedded(streamIndex: stream.index)))
        }
        guard generation == self.generation else { return }
        subtitleTracks = tracks

        let settings = AppSettings.shared
        guard settings.autoLoadSubtitles else { return }
        // Exact matches for any preferred language beat a track that doesn't say which variant it is.
        if let track = SubtitleLanguage.best(tracks, for: settings.subtitleLanguages, language: \.language) {
            await select(subtitle: track)
            return
        }
        let sidecars = tracks.filter { if case .embedded = $0.source { false } else { true } }
        if sidecars.count == 1, sidecars[0].language == nil {
            await select(subtitle: sidecars[0])
        } else if !settings.openSubtitlesKey.isEmpty {
            await searchOnline(autoSelect: true)
        }
    }

    func select(subtitle track: SubtitleTrack?) async {
        let generation = generation
        guard let track else {
            selectedSubtitleID = nil
            loadingSubtitleID = nil
            cues = []
            cueText = nil
            if mode == .hls(withSubtitles: true) { reopen(forceHLS: false, withSubtitles: false) }
            return
        }
        loadingSubtitleID = track.id
        subtitleFailures[track.id] = nil
        do {
            let loaded = try await loadCues(for: track)
            guard generation == self.generation, loadingSubtitleID == track.id else { return }
            loadingSubtitleID = nil
            guard !loaded.isEmpty else {
                subtitleFailures[track.id] = "That subtitle file is empty."
                return
            }
            selectedSubtitleID = track.id
            cues = loaded
            if isExternal { reopen(forceHLS: true, withSubtitles: true) }
        } catch {
            guard generation == self.generation, loadingSubtitleID == track.id else { return }
            loadingSubtitleID = nil
            subtitleFailures[track.id] = error.localizedDescription
        }
    }

    private func loadCues(for track: SubtitleTrack) async throws -> [SubtitleCue] {
        switch track.source {
        case .file(let url):
            return SubtitleParser.parse(SubtitleParser.decode(try Data(contentsOf: url)), fileExtension: url.pathExtension)

        case .torrentFile(let hash, let index, let absolutePath, let size):
            let session = server.session
            session.setPriority(7, forFile: Int32(index), inTorrent: hash)
            session.prioritizeTorrent(hash, file: Int32(index), offset: 0, window: max(size, 1))
            for _ in 0..<240 {
                if session.contiguousBytes(inTorrent: hash, file: Int32(index), offset: 0) >= size { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: PartFile.resolve(absolutePath)))
            return SubtitleParser.parse(SubtitleParser.decode(data), fileExtension: (absolutePath as NSString).pathExtension)

        case .embedded(let streamIndex):
            guard let ffmpeg = AppPaths.helper("ffmpeg") else { return [] }
            let args = ["-v", "quiet", "-nostdin", "-i", toolInput, "-map", "0:\(streamIndex)", "-f", "webvtt", "-"]
            guard let output = await ProcessRunner.run(ffmpeg, args, timeout: 1800) else { return [] }
            return SubtitleParser.parse(SubtitleParser.decode(output.stdout), fileExtension: "vtt")

        case .online(let fileID):
            let url = try await OpenSubtitles.shared.download(fileID: fileID)
            return SubtitleParser.parse(SubtitleParser.decode(try Data(contentsOf: url)), fileExtension: "srt")
        }
    }

    func addSubtitleFile(_ url: URL) {
        let track = SubtitleTrack(id: "file:\(url.path)", name: url.lastPathComponent,
                                  language: SubtitleLanguage.guess(fromFilename: url.lastPathComponent),
                                  detail: "File", source: .file(url))
        if !subtitleTracks.contains(where: { $0.id == track.id }) { subtitleTracks.append(track) }
        Task { await select(subtitle: track) }
    }

    /// Hash of the file for exact subtitle matching; needs only the first and last 64 KB to have arrived.
    private func movieHash() -> String? {
        guard let item else { return nil }
        if case .torrent(let hash, let index, _, _, let size) = item.origin {
            let chunk = Int64(OpenSubtitles.chunkSize)
            guard size >= chunk,
                  server.session.contiguousBytes(inTorrent: hash, file: Int32(index), offset: 0) >= chunk,
                  server.session.contiguousBytes(inTorrent: hash, file: Int32(index), offset: size - chunk) >= chunk
            else { return nil }
        }
        return OpenSubtitles.hash(fileAt: URL(fileURLWithPath: PartFile.resolve(item.absolutePath)))
    }

    func searchOnline(autoSelect: Bool = false, query customQuery: String? = nil) async {
        guard let item else { return }
        let generation = generation
        searchToken += 1
        let token = searchToken
        onlineResults = []
        onlineSearch = .searching

        var parsed = ReleaseNameParser.parse((item.absolutePath as NSString).lastPathComponent)
        if let id = item.libraryID, let saved = library.item(id), saved.isMatched {
            parsed.title = saved.kind == .episode ? (saved.showTitle ?? saved.title) : saved.title
            parsed.season = saved.season ?? parsed.season
            parsed.episode = saved.episode ?? parsed.episode
            parsed.year = saved.year ?? parsed.year
        }
        let query = customQuery ?? parsed.title
        let isFileMatch = customQuery == nil
        let hash = isFileMatch ? movieHash() : nil
        let languages = AppSettings.shared.subtitleLanguages
        do {
            var results = try await OpenSubtitles.shared.search(
                query: query, movieHash: hash, season: isFileMatch ? parsed.season : nil,
                episode: isFileMatch ? parsed.episode : nil, year: isFileMatch ? parsed.year : nil, languages: languages)
            // A wrong year in the file name shouldn't hide every result.
            if results.isEmpty, isFileMatch, parsed.year != nil, parsed.season == nil {
                results = try await OpenSubtitles.shared.search(
                    query: query, movieHash: hash, season: nil, episode: nil, year: nil, languages: languages)
            }
            guard generation == self.generation, token == searchToken else { return }
            onlineResults = results
            onlineSearch = .finished(query: query)
            if autoSelect, let best = results.first { await select(online: best) }
        } catch {
            guard generation == self.generation, token == searchToken else { return }
            onlineSearch = .failed(error.localizedDescription)
        }
    }

    func select(online result: OnlineSubtitle) async {
        let track = SubtitleTrack(id: "online:\(result.fileID)", name: result.release, language: result.language,
                                  detail: result.hashMatch ? "Exact match" : "OpenSubtitles",
                                  source: .online(fileID: result.fileID))
        if !subtitleTracks.contains(where: { $0.id == track.id }) { subtitleTracks.append(track) }
        await select(subtitle: track)
    }
}
