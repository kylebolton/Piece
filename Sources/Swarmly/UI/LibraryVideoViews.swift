import SwiftUI

enum VideoSort: String, CaseIterable {
    case title = "Title", year = "Year", added = "Date Added", rating = "Rating"
}

@MainActor
func importFolder(into library: LibraryStore) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.message = "Choose a folder of films, shows or music to add to your library"
    panel.prompt = "Add to Library"
    if panel.runModal() == .OK, let url = panel.url { library.importFolder(url) }
}

struct LibraryMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Button("Add Folder to Library…", systemImage: "folder.badge.plus") { importFolder(into: app.library) }
            Button("Refresh Info for Everything", systemImage: "arrow.clockwise") {
                app.library.refreshMetadata(for: app.library.items.filter { $0.kind != .other }.map(\.id))
            }
            Button("Remove Missing Files", systemImage: "questionmark.folder") { app.library.removeMissing() }
        } label: {
            Label("Library", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Films

struct FilmsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("filmSort") private var sort = VideoSort.added
    @AppStorage("filmUnwatchedOnly") private var unwatchedOnly = false
    @State private var filter = ""
    @State private var detail: MediaItem?
    @State private var fixing: MediaItem?

    private var films: [MediaItem] {
        var films = app.library.films
        if unwatchedOnly { films = films.filter { !$0.isWatched } }
        if !filter.isEmpty {
            let needle = filter.lowercased()
            films = films.filter { $0.title.lowercased().contains(needle) || $0.genreText.lowercased().contains(needle) || $0.yearText.contains(needle) }
        }
        switch sort {
        case .title: return films.sorted { $0.sortTitle < $1.sortTitle }
        case .year: return films.sorted { ($0.sortYear, $1.sortTitle) > ($1.sortYear, $0.sortTitle) }
        case .added: return films.sorted { $0.dateAdded > $1.dateAdded }
        case .rating: return films.sorted { $0.sortRating > $1.sortRating }
        }
    }

    var body: some View {
        let films = films
        VStack(spacing: 0) {
            ContentHeader(title: "Films", subtitle: app.library.films.isEmpty ? nil : "\(films.count)") {
                Toggle("Unwatched", isOn: $unwatchedOnly).toggleStyle(.button).controlSize(.small)
                Picker("Sort by", selection: $sort) {
                    ForEach(VideoSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                FilterField(text: $filter)
                LibraryMenu()
            }
            if app.library.films.isEmpty {
                EmptyState(symbol: "film", title: "No films yet",
                           message: "Films you download are added here automatically, with posters and details. You can also add a folder you already have.",
                           actionTitle: "Add Folder…") { importFolder(into: app.library) }
            } else if films.isEmpty {
                EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No films match", message: "Try a different filter.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)], spacing: 24) {
                        ForEach(films) { film in
                            PosterCell(title: film.title, subtitle: film.yearText, artwork: film.artworkURL, symbol: "film",
                                       progress: film.watchedFraction, isWatched: film.isWatched, badge: film.resolution) {
                                detail = film
                            } play: {
                                app.play(film)
                            }
                            .contextMenu { videoMenu(for: film) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(item: $detail) { MediaDetailSheet(itemID: $0.id) }
        .sheet(item: $fixing) { FixMatchSheet(item: $0) }
    }

    @ViewBuilder
    private func videoMenu(for film: MediaItem) -> some View {
        Button("Play", systemImage: "play.fill") { app.play(film) }
        Button("Play from Beginning", systemImage: "backward.end") { app.play(film, fromStart: true) }
        Divider()
        Button(film.isWatched ? "Mark as Unwatched" : "Mark as Watched", systemImage: film.isWatched ? "circle" : "checkmark.circle") {
            app.library.setWatched(!film.isWatched, ids: [film.id])
        }
        Button("Fix Match…", systemImage: "wand.and.stars") { fixing = film }
        Button("Move to TV Shows", systemImage: "tv") { app.library.changeKind(of: film.id, to: .episode) }
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([film.url]) }
        Divider()
        Button("Remove from Library", systemImage: "minus.circle") { app.library.remove([film.id], moveToTrash: false) }
        Button("Move to Trash", systemImage: "trash", role: .destructive) { app.library.remove([film.id], moveToTrash: true) }
    }
}

struct PosterCell: View {
    var title: String
    var subtitle: String
    var artwork: URL?
    var symbol: String
    var progress: Double = 0
    var isWatched = false
    var badge: String?
    var aspect: CGFloat = 2.0 / 3.0
    var open: () -> Void
    var play: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                ArtworkView(url: artwork, symbol: symbol, cornerRadius: 10)
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if progress > 0.02, !isWatched {
                            ProgressBar(value: progress, tint: .white, height: 3)
                                .padding(8)
                                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                        }
                    }
                    .overlay {
                        if isHovering {
                            Button(action: play) {
                                Image(systemName: "play.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white)
                                    .frame(width: 50, height: 50)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                            .accessibilityLabel("Play \(title)")
                        }
                    }
                    .shadow(color: .black.opacity(isHovering ? 0.28 : 0.14), radius: isHovering ? 12 : 6, y: isHovering ? 6 : 3)
                    .scaleEffect(isHovering ? 1.025 : 1)
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if !isWatched, progress <= 0.02 {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("Unwatched")
                    }
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                }
                Text(subtitle.isEmpty ? " " : subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Details for a film or a single episode.
struct MediaDetailSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var itemID: UUID
    @State private var fixing: MediaItem?

    var body: some View {
        if let item = app.library.item(itemID) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    ArtworkView(url: item.backdropURL ?? item.artworkURL, symbol: "film", cornerRadius: 0, maxPixel: 1400)
                        .frame(height: 250)
                        .clipped()
                        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                    HStack(alignment: .bottom, spacing: 16) {
                        ArtworkView(url: item.artworkURL, symbol: "film", cornerRadius: 8)
                            .frame(width: 100, height: 150)
                            .shadow(radius: 10, y: 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.kind == .episode ? (item.showTitle ?? item.title) : item.title)
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(metaLine(for: item))
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(20)
                }
                .overlay(alignment: .topTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Button {
                            app.play(item)
                            dismiss()
                        } label: {
                            Label(item.playPosition > 30 && !item.isWatched ? "Resume" : "Play", systemImage: "play.fill")
                                .frame(minWidth: 80)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)

                        if item.playPosition > 30, !item.isWatched {
                            Button("From Beginning") {
                                app.play(item, fromStart: true)
                                dismiss()
                            }
                            .controlSize(.large)
                            Text("\(Format.duration(item.playPosition)) watched").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button(item.isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                                app.library.setWatched(!item.isWatched, ids: [item.id])
                            }
                            if item.kind == .film { Button("Fix Match…") { fixing = item } }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    if item.kind == .episode {
                        Text("\(item.episodeCode) · \(item.title)").font(.headline)
                    }
                    if let overview = item.overview, !overview.isEmpty {
                        ScrollView { Text(overview).font(.callout).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 130)
                    } else if !item.isMatched {
                        Text(MetadataService.hasTMDB ? "No details were found for this title. Use Fix Match to search by a different name."
                             : "Add a TMDB key in Settings → Library for posters, descriptions and ratings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text((item.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(20)
            }
            .frame(width: 620)
            .sheet(item: $fixing) { FixMatchSheet(item: $0) }
        }
    }

    private func metaLine(for item: MediaItem) -> String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if item.duration > 0 { parts.append(Format.runtime(item.duration)) }
        if !item.genres.isEmpty { parts.append(item.genres.prefix(3).joined(separator: ", ")) }
        if let rating = item.rating { parts.append(String(format: "★ %.1f", rating)) }
        if let resolution = item.resolution { parts.append(resolution) }
        return parts.joined(separator: "  ·  ")
    }
}

struct FixMatchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var item: MediaItem?
    var show: Show?
    @State private var query = ""
    @State private var candidates: [MetadataMatch] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix Match").font(.title2.weight(.semibold))
            HStack {
                TextField("Title", text: $query).textFieldStyle(.roundedBorder).onSubmit(search)
                Button("Search", action: search).disabled(query.isEmpty || isSearching)
            }
            Group {
                if isSearching {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    Text(hasSearched ? "No matches. Try a shorter or different title." : "Search for the correct title.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(candidates) { match in
                        Button {
                            choose(match)
                        } label: {
                            HStack(spacing: 10) {
                                AsyncImage(url: match.posterURL) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(.quaternary)
                                }
                                .frame(width: 40, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.title).font(.body.weight(.medium))
                                    Text(match.year.map(String.init) ?? "Unknown year").font(.caption).foregroundStyle(.secondary)
                                    if let overview = match.overview {
                                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            query = show?.title ?? item?.title ?? ""
            search()
        }
    }

    private func search() {
        guard !query.isEmpty else { return }
        isSearching = true
        Task {
            candidates = show != nil ? await MetadataService.showCandidates(query: query) : await MetadataService.filmCandidates(query: query)
            isSearching = false
            hasSearched = true
        }
    }

    private func choose(_ match: MetadataMatch) {
        Task {
            if let show { await app.library.apply(match, toShow: show) } else if let item { await app.library.apply(match, to: item.id) }
        }
        dismiss()
    }
}

// MARK: - TV

struct TVView: View {
    @Environment(AppModel.self) private var app
    @State private var filter = ""
    @State private var openShowID: String?
    @State private var fixing: Show?

    var body: some View {
        let all = app.library.shows
        if let id = openShowID, let show = all.first(where: { $0.id == id }) {
            ShowDetailView(show: show) { openShowID = nil }
        } else {
            let shows = filter.isEmpty ? all : all.filter { $0.title.lowercased().contains(filter.lowercased()) }
            VStack(spacing: 0) {
                ContentHeader(title: "TV Shows", subtitle: all.isEmpty ? nil : "\(shows.count)") {
                    FilterField(text: $filter)
                    LibraryMenu()
                }
                if all.isEmpty {
                    EmptyState(symbol: "tv", title: "No TV shows yet",
                               message: "Episodes you download are grouped into shows and seasons here.",
                               actionTitle: "Add Folder…") { importFolder(into: app.library) }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20, alignment: .top)], spacing: 24) {
                            ForEach(shows) { show in
                                PosterCell(title: show.title,
                                           subtitle: "\(show.episodes.count) episode\(show.episodes.count == 1 ? "" : "s")",
                                           artwork: show.artworkURL, symbol: "tv", isWatched: show.unwatchedCount == 0) {
                                    openShowID = show.id
                                } play: {
                                    if let next = nextEpisode(of: show) { app.play(next) }
                                }
                                .contextMenu {
                                    Button("Play Next Episode", systemImage: "play.fill") {
                                        if let next = nextEpisode(of: show) { app.play(next) }
                                    }
                                    Button("Fix Match…", systemImage: "wand.and.stars") { fixing = show }
                                    Button("Mark All as Watched", systemImage: "checkmark.circle") {
                                        app.library.setWatched(true, ids: Set(show.episodes.map(\.id)))
                                    }
                                    Divider()
                                    Button("Remove from Library", systemImage: "minus.circle") {
                                        app.library.remove(Set(show.episodes.map(\.id)), moveToTrash: false)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .sheet(item: $fixing) { FixMatchSheet(show: $0) }
        }
    }

    private func nextEpisode(of show: Show) -> MediaItem? {
        let ordered = show.episodes.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        return ordered.first { !$0.isWatched } ?? ordered.first
    }
}

struct ShowDetailView: View {
    @Environment(AppModel.self) private var app
    var show: Show
    var back: () -> Void
    @State private var season: Int?
    @State private var detail: MediaItem?

    var body: some View {
        let seasons = show.seasons
        let current = season.flatMap { seasons.contains($0) ? $0 : nil } ?? seasons.first ?? 1
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(url: show.backdropURL ?? show.artworkURL, symbol: "tv", cornerRadius: 0, maxPixel: 1600)
                    .frame(height: 200)
                    .clipped()
                    .overlay(LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                HStack(alignment: .bottom, spacing: 16) {
                    ArtworkView(url: show.artworkURL, symbol: "tv", cornerRadius: 8)
                        .frame(width: 86, height: 129)
                        .shadow(radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.title).font(.largeTitle.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                        Text("\(seasons.count) season\(seasons.count == 1 ? "" : "s")  ·  \(show.episodes.count) episodes  ·  \(show.unwatchedCount) unwatched")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                        if let overview = show.overview {
                            Text(overview).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(2).frame(maxWidth: 560, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
            .overlay(alignment: .topLeading) {
                Button(action: back) {
                    Label("TV Shows", systemImage: "chevron.left")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.45), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(12)
                .keyboardShortcut(.cancelAction)
            }

            if seasons.count > 1 {
                Picker("Season", selection: Binding(get: { current }, set: { season = $0 })) {
                    ForEach(seasons, id: \.self) { Text($0 == 0 ? "Specials" : "Season \($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 12)
            }

            List(show.episodes(inSeason: current)) { episode in
                HStack(spacing: 12) {
                    Text(episode.episode.map(String.init) ?? "–")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if !episode.isWatched { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("Unwatched") }
                            Text(episode.title).font(.body.weight(.medium)).lineLimit(1)
                        }
                        if let overview = episode.overview, episode.isMatched {
                            Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if episode.watchedFraction > 0.02, !episode.isWatched {
                            ProgressBar(value: episode.watchedFraction, height: 3).frame(width: 120)
                        }
                    }
                    Spacer()
                    if episode.duration > 0 {
                        Text(Format.runtime(episode.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button { app.play(episode) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Play episode \(episode.episode ?? 0)")
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { app.play(episode) }
                .contextMenu {
                    Button("Play", systemImage: "play.fill") { app.play(episode) }
                    Button("Play from Beginning", systemImage: "backward.end") { app.play(episode, fromStart: true) }
                    Button("Details", systemImage: "info.circle") { detail = episode }
                    Button(episode.isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                        app.library.setWatched(!episode.isWatched, ids: [episode.id])
                    }
                    Button("Move to Films", systemImage: "film") { app.library.changeKind(of: episode.id, to: .film) }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([episode.url]) }
                    Divider()
                    Button("Remove from Library", systemImage: "minus.circle") { app.library.remove([episode.id], moveToTrash: false) }
                }
            }
            .listStyle(.inset)
        }
        .sheet(item: $detail) { MediaDetailSheet(itemID: $0.id) }
    }
}
