import AVFoundation
import Foundation

/// Queue-based music player behind the mini player bar in the main window.
@MainActor
@Observable
final class AudioPlayer {
    @ObservationIgnored let player = AVPlayer()

    private(set) var queue: [MediaItem] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0

    @ObservationIgnored private let server: StreamServer
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var hls: HLSSession?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(server: StreamServer, library: LibraryStore) {
        self.server = server
        self.library = library
        player.allowsExternalPlayback = true
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.time = time.seconds
                let length = self.player.currentItem?.duration.seconds ?? 0
                if length.isFinite, length > 0 { self.duration = length }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                if let current = self.current { self.library.update(current.id) { $0.playCount += 1; $0.lastPlayed = Date() } }
                self.next()
            }
        }
    }

    var current: MediaItem? { queue.indices.contains(index) ? queue[index] : nil }
    var hasNext: Bool { index + 1 < queue.count }

    func play(_ tracks: [MediaItem], startingAt start: Int = 0) {
        queue = tracks
        index = min(max(0, start), max(0, tracks.count - 1))
        loadCurrent()
    }

    private func loadCurrent() {
        hls?.stop()
        hls = nil
        guard let track = current else { return stop() }
        time = 0
        duration = track.duration
        let ext = (track.path as NSString).pathExtension.lowercased()
        let url: URL
        if FileKind.nativeExtensions.contains(ext) {
            url = track.url
        } else {
            // Ogg, Opus, WMA and friends go through ffmpeg.
            let session = HLSSession(server: server)
            guard session.start(input: track.path, probe: nil) else { return next() }
            hls = session
            url = session.masterURL
        }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    func toggle() {
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    func next() {
        guard hasNext else { return stop() }
        index += 1
        loadCurrent()
    }

    func previous() {
        if time > 3 || index == 0 {
            player.seek(to: .zero)
        } else {
            index -= 1
            loadCurrent()
        }
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * min(max(fraction, 0), 1), preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        hls?.stop()
        hls = nil
        queue = []
        index = 0
        time = 0
        duration = 0
    }
}
