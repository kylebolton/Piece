import Charts
import SwiftUI

/// The menu bar popover: live speeds, a library search, and the transfers in progress.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var parsed: SearchQuery { SearchQuery(query) }

    private var libraryHits: [MediaItem] {
        let ids = SearchIndex.matching(app.library.items, parsed, tags: app.tags)
        return app.library.items.filter { ids.contains($0.id) && ($0.kind != .track || !parsed.words.isEmpty) }
            .sorted { $0.dateAdded > $1.dateAdded }
            .prefix(6).map { $0 }
    }

    private var transferHits: [Torrent] {
        app.torrents.torrents.filter { SearchIndex.matches(SearchIndex.document(for: $0, tags: app.tags.tags(for: $0.id)), parsed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            if parsed.isEmpty { activeTransfers } else { results }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { searchFocused = true }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Label(Format.rate(app.torrents.downloadRate), systemImage: "arrow.down")
                    .foregroundStyle(app.torrents.downloadRate > 0 ? Color.accentColor : .secondary)
                Label(Format.rate(app.torrents.uploadRate), systemImage: "arrow.up")
                    .foregroundStyle(app.torrents.uploadRate > 0 ? Color.green : .secondary)
                Spacer()
                Button { app.torrents.pauseAll() } label: { Image(systemName: "pause.fill") }.help("Pause all")
                Button { app.torrents.resumeAll() } label: { Image(systemName: "play.fill") }.help("Resume all")
            }
            .buttonStyle(.borderless)
            .font(.callout.weight(.medium))
            .monospacedDigit()

            Chart {
                ForEach(Array(app.torrents.speedHistory.enumerated()), id: \.offset) { index, sample in
                    AreaMark(x: .value("Time", index), y: .value("Down", sample.down), series: .value("Series", "down"))
                        .foregroundStyle(Color.accentColor.opacity(0.35))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", index), y: .value("Up", sample.up), series: .value("Series", "up"))
                        .foregroundStyle(Color.green)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 44)
            .accessibilityLabel("Speed history")
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search library and transfers  ·  #tag", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { openFirstHit() }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var activeTransfers: some View {
        let active = app.torrents.torrents.filter { !$0.isComplete }
        if active.isEmpty {
            Text("No transfers in progress").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(active.prefix(5)) { TransferLine(torrent: $0) }
                if active.count > 5 { Text("+ \(active.count - 5) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let library = libraryHits
        let transfers = transferHits
        if library.isEmpty && transfers.isEmpty {
            VStack(spacing: 8) {
                Text("Nothing matches “\(query)”").font(.callout).foregroundStyle(.secondary)
                Button("Search torrents for “\(query)”", systemImage: "magnifyingglass") { searchTorrents() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(library) { item in
                    Button { open(item) } label: {
                        HStack(spacing: 8) {
                            ArtworkView(url: item.artworkURL, symbol: symbol(for: item), cornerRadius: 3, maxPixel: 80)
                                .frame(width: 24, height: 34)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).lineLimit(1)
                                Text([item.kind == .episode ? item.episodeCode : item.yearText, item.kind.rawValue.capitalized]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(transfers.prefix(4)) { TransferLine(torrent: $0) }
                Button("Search torrents for “\(query)”", systemImage: "magnifyingglass") { searchTorrents() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.top, 4)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Piece", systemImage: "macwindow") { showMain() }
            Button("Add Magnet", systemImage: "link.badge.plus") { _ = app.addFromPasteboard() }
                .help("Add the magnet link on the clipboard")
            Spacer()
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .help("Quit Piece")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    // MARK: - Actions

    private func symbol(for item: MediaItem) -> String {
        switch item.kind {
        case .film: "film"
        case .episode: "tv"
        case .track: "music.note"
        case .other: "doc"
        }
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func open(_ item: MediaItem) {
        switch item.kind {
        case .film, .episode, .track: app.play(item)
        case .other: NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    private func searchTorrents() {
        app.search.query = query
        app.selection = .search
        app.search.search()
        showMain()
    }

    private func openFirstHit() {
        if let first = libraryHits.first { open(first) } else if transferHits.isEmpty { searchTorrents() }
    }
}

private struct TransferLine: View {
    @Environment(AppModel.self) private var app
    var torrent: Torrent

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, torrent.progress))
                    .stroke(torrent.phase.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(torrent.name).lineLimit(1).truncationMode(.middle)
                Text(torrent.statusLine).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { app.torrents.toggle(torrent) } label: {
                Image(systemName: torrent.phase == .paused ? "play.circle" : "pause.circle")
            }
            .buttonStyle(.borderless)
            .help(torrent.phase == .paused ? "Resume" : "Pause")
        }
        .font(.callout)
    }
}
