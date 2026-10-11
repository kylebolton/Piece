import SwiftUI

/// One thing standing on the shelf: a film, a show or an album.
struct ShelfEntry: Identifiable {
    enum Source {
        case film(MediaItem)
        case show(Show)
        case album(Album)
    }

    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
    let symbol: String
    let source: Source
    let document: SearchDocument
    let dateAdded: Date
    let targets: [String]
    let progress: Double
    let isWatched: Bool
    var isPacked = false
}

extension ShelfEntry {
    /// Builds the entries for a library, merging each member's searchable text and tags.
    @MainActor
    static func build(from library: LibraryStore, tags: TagStore) -> [ShelfEntry] {
        func document(id: String, members: [MediaItem], extra: String) -> SearchDocument {
            let docs = members.map { SearchIndex.document(for: $0, tags: tags.tags(for: $0.id.uuidString)) }
            return SearchDocument(target: id, text: ([extra] + docs.map(\.text)).joined(separator: " ").lowercased(),
                                  tagNames: docs.reduce(into: Set<String>()) { $0.formUnion($1.tagNames) })
        }

        var entries: [ShelfEntry] = []
        for film in library.films {
            entries.append(ShelfEntry(id: "film-\(film.id)", title: film.title, subtitle: film.yearText, artwork: film.artworkURL,
                                      symbol: "film", source: .film(film), document: document(id: film.id.uuidString, members: [film], extra: ""),
                                      dateAdded: film.dateAdded, targets: [film.id.uuidString], progress: film.watchedFraction,
                                      isWatched: film.isWatched))
        }
        for show in library.shows {
            let count = show.episodes.count
            entries.append(ShelfEntry(id: "show-\(show.id)", title: show.title, subtitle: "\(count) episode\(count == 1 ? "" : "s")",
                                      artwork: show.artworkURL, symbol: "tv", source: .show(show),
                                      document: document(id: show.id, members: show.episodes, extra: show.title),
                                      dateAdded: show.dateAdded, targets: show.episodes.map { $0.id.uuidString }, progress: 0,
                                      isWatched: show.unwatchedCount == 0))
        }
        for album in library.albums {
            entries.append(ShelfEntry(id: "album-\(album.id)", title: album.title, subtitle: album.artist, artwork: album.artworkURL,
                                      symbol: "music.note", source: .album(album),
                                      document: document(id: album.id, members: album.tracks, extra: "\(album.title) \(album.artist)"),
                                      dateAdded: album.tracks.map(\.dateAdded).max() ?? .distantPast,
                                      targets: album.tracks.map { $0.id.uuidString }, progress: 0, isWatched: true))
        }
        return entries.map { entry in
            var entry = entry
            let ids = entry.targets.compactMap(UUID.init(uuidString:)).compactMap(library.item)
            entry.isPacked = !ids.isEmpty && ids.allSatisfy(\.isPacked)
            return entry
        }
    }
}

/// An Apple Books–style library: everything standing on wooden shelves. Searching dims whatever doesn't match,
/// and the matches slide to the front shelf.
struct ShelfView: View {
    @Environment(AppModel.self) private var app
    var tag: Tag?

    @State private var detail: MediaItem?
    @State private var openShow: Show?

    private let itemWidth: CGFloat = 132
    private let gap: CGFloat = 26

    var body: some View {
        @Bindable var app = app
        let query = SearchQuery(app.shelfQuery)
        let entries = visibleEntries(query: query)
        VStack(spacing: 0) {
            ContentHeader(title: tag?.name ?? "Shelf", subtitle: entries.isEmpty ? nil : "\(entries.count)") {
                ShelfSearchField(text: $app.shelfQuery)
                LibraryMenu()
            }
            if app.library.items.isEmpty {
                EmptyState(symbol: "books.vertical", title: "Your shelf is empty",
                           message: "Finished downloads are added here automatically, or add a folder you already have.",
                           actionTitle: "Add Folder…") { importFolder(into: app.library) }
            } else if entries.isEmpty {
                EmptyState(symbol: "tag", title: "Nothing here yet", message: "Tag films, shows and albums to collect them on this shelf.")
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        shelves(entries, query: query, width: proxy.size.width)
                    }
                }
                .background(ShelfBackdrop())
                if !query.isEmpty { searchFooter(entries: entries, query: query) }
            }
        }
        .sheet(item: $detail) { MediaDetailSheet(itemID: $0.id) }
        .sheet(item: $openShow) { show in
            ShowDetailView(show: show) { openShow = nil }.frame(minWidth: 760, minHeight: 520)
        }
    }

    private func visibleEntries(query: SearchQuery) -> [ShelfEntry] {
        var all = ShelfEntry.build(from: app.library, tags: app.tags)
        if let tag {
            let tagged = app.tags.targets(with: tag)
            all = all.filter { entry in entry.targets.contains(where: tagged.contains) }
        }
        all.sort { $0.dateAdded > $1.dateAdded }
        guard !query.isEmpty else { return all }
        // Matches first, in their usual order, then the dimmed rest.
        let hit = all.filter { SearchIndex.matches($0.document, query) }
        let rest = all.filter { !SearchIndex.matches($0.document, query) }
        return hit + rest
    }

    private func shelves(_ entries: [ShelfEntry], query: SearchQuery, width: CGFloat) -> some View {
        let perRow = max(1, Int((width - 48 + gap) / (itemWidth + gap)))
        let rows = stride(from: 0, to: entries.count, by: perRow).map { Array(entries[$0..<min($0 + perRow, entries.count)]) }
        return VStack(spacing: 30) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ShelfRow(entries: row, query: query, itemWidth: itemWidth, gap: gap) { entry in
                    open(entry)
                } play: { entry in
                    play(entry)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .animation(.smooth(duration: 0.45), value: entries.map(\.id))
        .animation(.smooth(duration: 0.3), value: query)
    }

    private func searchFooter(entries: [ShelfEntry], query: SearchQuery) -> some View {
        let hits = entries.filter { SearchIndex.matches($0.document, query) }.count
        return HStack {
            Text(hits == 0 ? "Nothing in your library matches" : "\(hits) in your library")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Search Torrents for “\(app.shelfQuery)”", systemImage: "magnifyingglass") {
                app.search.query = app.shelfQuery
                app.selection = .search
                app.search.search()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func open(_ entry: ShelfEntry) {
        switch entry.source {
        case .film(let item): detail = item
        case .show(let show): openShow = show
        case .album: app.selection = .music
        }
    }

    private func play(_ entry: ShelfEntry) {
        switch entry.source {
        case .film(let item): app.play(item)
        case .show(let show):
            let ordered = show.episodes.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
            if let next = ordered.first(where: { !$0.isWatched }) ?? ordered.first { app.play(next) }
        case .album(let album): app.play(tracks: album.tracks.sorted { $0.sortTrack < $1.sortTrack }, startingAt: 0)
        }
    }
}

private struct ShelfRow: View {
    @Environment(AppModel.self) private var app
    var entries: [ShelfEntry]
    var query: SearchQuery
    var itemWidth: CGFloat
    var gap: CGFloat
    var open: (ShelfEntry) -> Void
    var play: (ShelfEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ShelfPlank()
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(entries) { entry in
                        let matches = query.isEmpty || SearchIndex.matches(entry.document, query)
                        ShelfItem(entry: entry, width: itemWidth, isDimmed: !matches, isHighlighted: matches && !query.isEmpty,
                                  open: { open(entry) }, play: { play(entry) })
                            .contextMenu {
                                Button("Open", systemImage: "arrow.up.forward.square") { open(entry) }
                                Button("Play", systemImage: "play.fill") { play(entry) }
                                Divider()
                                TagMenu(targets: entry.targets)
                                StorageMenu(itemIDs: entry.targets.compactMap(UUID.init(uuidString:)))
                            }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            HStack(alignment: .top, spacing: gap) {
                ForEach(entries) { entry in
                    let matches = query.isEmpty || SearchIndex.matches(entry.document, query)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.caption.weight(.medium)).lineLimit(1)
                        Text(entry.subtitle.isEmpty ? " " : entry.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: itemWidth, alignment: .leading)
                    .opacity(matches ? 1 : 0.25)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
        }
    }
}

private struct ShelfItem: View {
    var entry: ShelfEntry
    var width: CGFloat
    var isDimmed: Bool
    var isHighlighted: Bool
    var open: () -> Void
    var play: () -> Void

    @State private var isHovering = false
    @State private var tilt = CGSize.zero

    private var isSquare: Bool { if case .album = entry.source { true } else { false } }

    var body: some View {
        let height = isSquare ? width : width * 1.5
        Button(action: open) {
            ZStack {
                ArtworkView(url: entry.artwork, symbol: entry.symbol, cornerRadius: 3, maxPixel: 400)
                // Spine: a darker, glossy edge on the left like a bound book or a case.
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 9)
                    Spacer()
                }
                // Gloss sweep across the cover.
                LinearGradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if isHovering {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(entry.title)")
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if entry.isPacked {
                    Image(systemName: "archivebox.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.6), in: Circle())
                        .padding(5)
                        .help("Packed — opens after unpacking")
                }
            }
            .saturation(entry.isPacked ? 0.35 : 1)
            .overlay(alignment: .bottom) {
                if entry.progress > 0.02, !entry.isWatched {
                    ProgressBar(value: entry.progress, tint: .white, height: 3).padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .rotation3DEffect(.degrees(isHovering ? Double(tilt.width) * 6 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .rotation3DEffect(.degrees(isHovering ? Double(-tilt.height) * 5 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        .scaleEffect(isHovering ? 1.04 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.5 : 0.35), radius: isHovering ? 14 : 6, x: 3, y: isHovering ? 10 : 5)
        .shadow(color: isHighlighted ? Color.accentColor.opacity(0.8) : .clear, radius: 14)
        // Search fade: non-matches sink back, desaturated and blurred.
        .opacity(isDimmed ? 0.22 : 1)
        .saturation(isDimmed ? 0.1 : 1)
        .blur(radius: isDimmed ? 2.5 : 0)
        .scaleEffect(isDimmed ? 0.92 : 1, anchor: .bottom)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                tilt = CGSize(width: (point.x / width - 0.5) * 2, height: (point.y / height - 0.5) * 2)
                if !isHovering { withAnimation(.smooth(duration: 0.2)) { isHovering = true } }
            case .ended:
                withAnimation(.smooth(duration: 0.25)) { isHovering = false }
            }
        }
        .animation(.smooth(duration: 0.3), value: isDimmed)
        .accessibilityLabel("\(entry.title), \(entry.subtitle)")
    }
}

/// A wooden plank with a lit front edge and a shadow beneath it.
private struct ShelfPlank: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .top) {
                LinearGradient(colors: scheme == .dark ? [Color(red: 0.32, green: 0.21, blue: 0.13), Color(red: 0.2, green: 0.12, blue: 0.07)]
                                                       : [Color(red: 0.72, green: 0.52, blue: 0.34), Color(red: 0.56, green: 0.38, blue: 0.23)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(.white.opacity(scheme == .dark ? 0.12 : 0.35)).frame(height: 1)
            }
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 6)
        }
        .frame(height: 24)
    }
}

/// The wall behind the shelves: a soft, slightly lit surface.
private struct ShelfBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(colors: scheme == .dark ? [Color(white: 0.13), Color(white: 0.09)] : [Color(white: 0.93), Color(white: 0.85)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(RadialGradient(colors: [.white.opacity(scheme == .dark ? 0.05 : 0.35), .clear],
                                    center: .top, startRadius: 20, endRadius: 520))
    }
}

/// The big search field that sits above the shelves.
struct ShelfSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search your library  ·  #tag", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.07), in: Capsule())
        .frame(width: 260)
    }
}
