import SwiftUI

struct MusicView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("musicMode") private var mode = Mode.songs
    @State private var filter = ""

    enum Mode: String, CaseIterable {
        case songs = "Songs", albums = "Albums", artists = "Artists"
    }

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Music", subtitle: app.library.tracks.isEmpty ? nil : "\(app.library.tracks.count) songs") {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                FilterField(text: $filter)
                LibraryMenu()
            }
            if app.library.tracks.isEmpty {
                EmptyState(symbol: "music.note", title: "No music yet",
                           message: "Albums and songs you download appear here, sorted by artist, album and track.",
                           actionTitle: "Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { app.library.importFolder(url) }
                }
            } else {
                switch mode {
                case .songs: SongsTable(filter: filter)
                case .albums: AlbumsGrid(albums: filtered(app.library.albums))
                case .artists: ArtistsBrowser(albums: filtered(app.library.albums))
                }
            }
        }
    }

    private func filtered(_ albums: [Album]) -> [Album] {
        guard !filter.isEmpty else { return albums }
        let needle = filter.lowercased()
        return albums.filter { $0.title.lowercased().contains(needle) || $0.artist.lowercased().contains(needle) }
    }
}

private struct SongsTable: View {
    @Environment(AppModel.self) private var app
    var filter: String
    @State private var sortOrder = [KeyPathComparator(\MediaItem.sortArtist), KeyPathComparator(\MediaItem.sortAlbum),
                                    KeyPathComparator(\MediaItem.sortTrack)]
    @State private var selection: Set<UUID> = []

    private var tracks: [MediaItem] {
        var tracks = app.library.tracks
        if !filter.isEmpty {
            let needle = filter.lowercased()
            tracks = tracks.filter {
                $0.title.lowercased().contains(needle) || $0.sortArtist.contains(needle) || $0.sortAlbum.contains(needle)
            }
        }
        return tracks.sorted(using: sortOrder)
    }

    var body: some View {
        let tracks = tracks
        let playingID = app.audio.current?.id
        Table(tracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.sortTitle) { track in
                HStack(spacing: 6) {
                    if track.id == playingID {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor).imageScale(.small)
                    }
                    Text(track.title).lineLimit(1)
                }
            }
            .width(min: 160, ideal: 280)
            TableColumn("Artist", value: \.sortArtist) { Text($0.artist ?? $0.albumArtist ?? "").lineLimit(1) }
                .width(min: 100, ideal: 170)
            TableColumn("Album", value: \.sortAlbum) { Text($0.album ?? "").lineLimit(1) }
                .width(min: 100, ideal: 190)
            TableColumn("#", value: \.sortTrack) { Text($0.trackNumber.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary) }
                .width(30)
            TableColumn("Time", value: \.duration) { Text($0.duration > 0 ? Format.duration($0.duration) : "").monospacedDigit().foregroundStyle(.secondary) }
                .width(50)
            TableColumn("Genre", value: \.sortGenre) { Text($0.genres.first ?? "").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 100)
            TableColumn("Year", value: \.sortYear) { Text($0.yearText).monospacedDigit().foregroundStyle(.secondary) }
                .width(44)
            TableColumn("Plays", value: \.playCount) { Text($0.playCount > 0 ? String($0.playCount) : "").monospacedDigit().foregroundStyle(.secondary) }
                .width(44)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Play", systemImage: "play.fill") { play(ids, in: tracks) }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting(tracks.filter { ids.contains($0.id) }.map(\.url))
            }
            Button("Refresh Info", systemImage: "arrow.clockwise") { app.library.refreshMetadata(for: Array(ids)) }
            Divider()
            Button("Remove from Library", systemImage: "minus.circle") { app.library.remove(ids, moveToTrash: false) }
            Button("Move to Trash", systemImage: "trash", role: .destructive) { app.library.remove(ids, moveToTrash: true) }
        } primaryAction: { ids in
            play(ids, in: tracks)
        }
    }

    /// Double-clicking a song plays it and carries on down the list, like iTunes.
    private func play(_ ids: Set<UUID>, in tracks: [MediaItem]) {
        guard let index = tracks.firstIndex(where: { ids.contains($0.id) }) else { return }
        app.play(tracks: tracks, startingAt: index)
    }
}

private struct AlbumsGrid: View {
    @Environment(AppModel.self) private var app
    var albums: [Album]
    @State private var open: Album?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)], spacing: 22) {
                ForEach(albums) { album in
                    PosterCell(title: album.title, subtitle: album.artist, artwork: album.artworkURL, symbol: "music.note",
                               isWatched: true, aspect: 1) {
                        open = album
                    } play: {
                        app.play(tracks: album.tracks, startingAt: 0)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .sheet(item: $open) { AlbumSheet(album: $0) }
    }
}

private struct AlbumSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var album: Album

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 16) {
                ArtworkView(url: album.artworkURL, symbol: "music.note", cornerRadius: 8)
                    .frame(width: 130, height: 130)
                    .shadow(radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title).font(.title2.weight(.bold)).lineLimit(2)
                    Text(album.artist).font(.title3).foregroundStyle(Color.accentColor)
                    Text([album.year.map(String.init), "\(album.tracks.count) songs", Format.runtime(album.duration)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        app.play(tracks: album.tracks, startingAt: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill").frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
                }
                Spacer()
            }
            .padding(20)

            List(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                HStack {
                    Text(track.trackNumber.map(String.init) ?? "\(index + 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    Text(track.title).lineLimit(1)
                    Spacer()
                    Text(track.duration > 0 ? Format.duration(track.duration) : "").monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { app.play(tracks: album.tracks, startingAt: index) }
            }
            .listStyle(.inset)
            .frame(height: 280)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 520)
    }
}

private struct ArtistsBrowser: View {
    var albums: [Album]
    @State private var selected: String?

    var body: some View {
        let artists = Array(Set(albums.map(\.artist))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let current = selected.flatMap { artists.contains($0) ? $0 : nil } ?? artists.first
        HStack(spacing: 0) {
            List(artists, id: \.self, selection: Binding(get: { current }, set: { selected = $0 })) { artist in
                Text(artist).lineLimit(1)
            }
            .listStyle(.inset)
            .frame(width: 220)
            Divider()
            AlbumsGrid(albums: albums.filter { $0.artist == current })
        }
    }
}

// MARK: - Other

struct OtherLibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var sortOrder = [KeyPathComparator(\MediaItem.dateAdded, order: .reverse)]
    @State private var selection: Set<UUID> = []

    var body: some View {
        let items = app.library.others.sorted(using: sortOrder)
        VStack(spacing: 0) {
            ContentHeader(title: "Other", subtitle: items.isEmpty ? nil : "\(items.count)") { LibraryMenu() }
            if items.isEmpty {
                EmptyState(symbol: "shippingbox", title: "Nothing here yet",
                           message: "Downloads that aren't films, shows or music — apps, books, disk images — are listed here.")
            } else {
                Table(items, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.sortTitle) { item in
                        Label(item.title, systemImage: FileKind(path: item.path).symbol).lineLimit(1)
                    }
                    TableColumn("Size", value: \.fileSize) { Text(Format.bytes($0.fileSize)).monospacedDigit().foregroundStyle(.secondary) }
                        .width(90)
                    TableColumn("Date Added", value: \.dateAdded) { Text(Format.shortDate.string(from: $0.dateAdded)).foregroundStyle(.secondary) }
                        .width(110)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Show in Finder", systemImage: "folder") { reveal(ids, in: items) }
                    Divider()
                    Button("Remove from Library", systemImage: "minus.circle") { app.library.remove(ids, moveToTrash: false) }
                } primaryAction: { ids in
                    reveal(ids, in: items)
                }
            }
        }
    }

    private func reveal(_ ids: Set<UUID>, in items: [MediaItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.filter { ids.contains($0.id) }.map(\.url))
    }
}

// MARK: - Mini player

struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let audio = app.audio
        if let track = audio.current {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 14) {
                    ArtworkView(url: track.artworkURL, symbol: "music.note", cornerRadius: 5, maxPixel: 120)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text([track.artist ?? track.albumArtist, track.album].compactMap { $0 }.joined(separator: " — "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 200, alignment: .leading)

                    HStack(spacing: 16) {
                        Button { audio.previous() } label: { Image(systemName: "backward.fill") }
                            .accessibilityLabel("Previous")
                        Button { audio.toggle() } label: {
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 24)
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                        Button { audio.next() } label: { Image(systemName: "forward.fill") }
                            .disabled(!audio.hasNext)
                            .accessibilityLabel("Next")
                    }
                    .buttonStyle(.plain)

                    Text(Format.duration(audio.time)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Slider(value: Binding(get: { audio.duration > 0 ? audio.time / audio.duration : 0 },
                                          set: { audio.seek(toFraction: $0) }))
                        .controlSize(.small)
                        .accessibilityLabel("Position")
                    Text(Format.duration(audio.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)

                    AirPlayButton(player: audio.player).frame(width: 26, height: 26).help("AirPlay")
                    Button { audio.stop() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Stop")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}
