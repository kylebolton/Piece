import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if app.audio.current != nil { MiniPlayerBar() }
                }
        }
        .inspector(isPresented: $app.showInspector) {
            TorrentInspector()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $app.showAddSheet) { AddTorrentSheet() }
        .confirmationDialog(removalTitle, isPresented: removalBinding, titleVisibility: .visible) {
            Button("Remove from List") { remove(deleteFiles: false) }
            Button("Remove and Delete Files", role: .destructive) { remove(deleteFiles: true) }
            Button("Cancel", role: .cancel) { app.pendingRemoval = [] }
        } message: {
            Text("Deleted files don't go to the Trash and can't be recovered.")
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { app.torrents.lastError = nil }
        } message: {
            Text(app.torrents.lastError ?? "")
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $isDropTarget, perform: handleDrop)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: app.playerRequest) { openWindow(id: "player") }
        .navigationTitle(title)
    }

    @ViewBuilder
    private var detail: some View {
        switch app.selection ?? .transfers(.all) {
        case .transfers(let filter): TransfersView(filter: filter)
        case .shelf: ShelfView()
        case .tag(let id): TagPageView(tagID: id)
        case .films: FilmsView()
        case .tv: TVView()
        case .music: MusicView()
        case .other: OtherLibraryView()
        case .search: SearchView()
        case .sources: SourcesView()
        }
    }

    /// Library and search screens carry their own large heading, so the toolbar stays quiet there.
    private var title: String {
        if case .transfers(let filter) = app.selection ?? .transfers(.all) { return filter.title }
        if case .tag(let id) = app.selection, let tag = app.tags.tag(id) { return tag.name }
        return "Piece"
    }

    private var isTransfers: Bool {
        if case .transfers = app.selection { return true }
        return false
    }

    private var selected: [Torrent] {
        app.torrents.torrents.filter { app.selectedTorrents.contains($0.id) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if isTransfers {
                Button {
                    selected.forEach { app.torrents.toggle($0) }
                } label: {
                    let allPaused = !selected.isEmpty && selected.allSatisfy { $0.phase == .paused || $0.phase == .completed }
                    Label(allPaused ? "Resume" : "Pause", systemImage: allPaused ? "play.fill" : "pause.fill")
                }
                .disabled(selected.isEmpty)
                .help("Pause or resume the selected transfers")

                Button {
                    app.pendingRemoval = selected
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(selected.isEmpty)
                .help("Remove the selected transfers")
            }

            Button {
                app.showAddSheet = true
            } label: {
                Label("Add Torrent", systemImage: "plus")
            }
            .help("Add a torrent from a magnet link or file")

            if isTransfers {
                Button {
                    app.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide details for the selected transfer")
            }
        }
    }

    // MARK: - Removal

    private var removalTitle: String {
        app.pendingRemoval.count == 1
            ? "Remove “\(app.pendingRemoval[0].name)”?"
            : "Remove \(app.pendingRemoval.count) transfers?"
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { !app.pendingRemoval.isEmpty }, set: { if !$0 { app.pendingRemoval = [] } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { app.torrents.lastError != nil }, set: { if !$0 { app.torrents.lastError = nil } })
    }

    private func remove(deleteFiles: Bool) {
        for torrent in app.pendingRemoval {
            app.torrents.remove(torrent, deleteFiles: deleteFiles)
            app.selectedTorrents.remove(torrent.id)
        }
        app.pendingRemoval = []
    }

    // MARK: - Drag and drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in app.open(urls: [url]) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in
                        _ = await app.torrents.add(link: text)
                        app.selection = .transfers(.all)
                    }
                }
            }
        }
        return handled
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section("Transfers") {
                ForEach(TransferFilter.allCases, id: \.self) { filter in
                    Label(filter.title, systemImage: filter.symbol)
                        .badge(count(for: filter))
                        .tag(SidebarItem.transfers(filter))
                }
            }
            Section("Library") {
                Label("Shelf", systemImage: "books.vertical").badge(app.library.items.filter { $0.kind != .track }.count).tag(SidebarItem.shelf)
                Label("Films", systemImage: "film").badge(app.library.count(of: .film)).tag(SidebarItem.films)
                Label("TV Shows", systemImage: "tv").badge(app.library.shows.count).tag(SidebarItem.tv)
                Label("Music", systemImage: "music.note").badge(app.library.count(of: .track)).tag(SidebarItem.music)
                Label("Other", systemImage: "shippingbox").badge(app.library.count(of: .other)).tag(SidebarItem.other)
            }
            Section {
                ForEach(app.tags.tags) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(tag.color).imageScale(.small)
                    }
                    .badge(app.tags.count(of: tag))
                    .tag(SidebarItem.tag(tag.id))
                    .contextMenu {
                        Button("Rename…", systemImage: "pencil") {
                            if let name = TagPrompt.ask(title: "Rename Tag", initial: tag.name) { app.tags.rename(tag, to: name) }
                        }
                        Menu("Color", systemImage: "paintpalette") {
                            ForEach(Array(Tag.palette.enumerated()), id: \.offset) { index, color in
                                Button { app.tags.recolor(tag, to: index) } label: { Label("Color \(index + 1)", systemImage: "circle.fill").foregroundStyle(color) }
                            }
                        }
                        Divider()
                        Button("Delete Tag", systemImage: "trash", role: .destructive) {
                            if app.selection == .tag(tag.id) { app.selection = .shelf }
                            app.tags.delete(tag)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Tags")
                    Spacer()
                    Button {
                        if let name = TagPrompt.ask() { app.tags.create(name: name) }
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("New tag")
                        .accessibilityLabel("New tag")
                }
            }
            Section("Discover") {
                Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                Label("Sources", systemImage: "globe").tag(SidebarItem.sources)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                StorageSummary()
                if let activity = app.library.activity {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(activity).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label(Format.rate(app.torrents.downloadRate), systemImage: "arrow.down")
                        .foregroundStyle(app.torrents.downloadRate > 0 ? Color.accentColor : Color.secondary)
                    Label(Format.rate(app.torrents.uploadRate), systemImage: "arrow.up")
                        .foregroundStyle(app.torrents.uploadRate > 0 ? Color.green : Color.secondary)
                    Spacer(minLength: 0)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func count(for filter: TransferFilter) -> Int {
        app.torrents.torrents.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
    }
}
