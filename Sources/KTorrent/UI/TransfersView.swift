import SwiftUI

struct TransfersView: View {
    @Environment(AppModel.self) private var app
    var filter: TransferFilter

    private var visible: [Torrent] { app.torrents.torrents.filter(filter.matches) }

    var body: some View {
        @Bindable var app = app
        let torrents = visible
        Group {
            if torrents.isEmpty {
                if filter == .all {
                    EmptyState(symbol: "arrow.down.circle", title: "No transfers yet",
                               message: "Drop a torrent file or magnet link here, paste a link, or find something in Search.",
                               actionTitle: "Add Torrent…") { app.showAddSheet = true }
                } else {
                    EmptyState(symbol: filter.symbol, title: "Nothing \(filter.title.lowercased())",
                               message: "Transfers will appear here as their status changes.")
                }
            } else {
                List(selection: $app.selectedTorrents) {
                    ForEach(torrents) { torrent in
                        TorrentRow(torrent: torrent)
                            .tag(torrent.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    contextMenu(for: app.torrents.torrents.filter { ids.contains($0.id) })
                } primaryAction: { ids in
                    app.selectedTorrents = ids
                    app.showInspector = true
                }
                .onDeleteCommand { app.pendingRemoval = torrents.filter { app.selectedTorrents.contains($0.id) } }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for torrents: [Torrent]) -> some View {
        if let first = torrents.first {
            if torrents.count == 1 {
                Button("Play", systemImage: "play.fill") { app.preview(first) }
                    .disabled(!first.hasMetadata)
                Divider()
            }
            Button("Resume", systemImage: "play") { torrents.forEach(app.torrents.resume) }
            Button("Pause", systemImage: "pause") { torrents.forEach(app.torrents.pause) }
            Divider()
            Button("Show in Finder", systemImage: "folder") { app.torrents.revealInFinder(first) }
            Button("Copy Magnet Link", systemImage: "link") {
                let links = torrents.compactMap(app.torrents.magnetLink).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links, forType: .string)
            }
            Button("Add to Library", systemImage: "books.vertical") { torrents.forEach(app.addToLibrary) }
                .disabled(!torrents.contains(where: \.hasMetadata))
            Divider()
            Button("Verify Files", systemImage: "checkmark.shield") { torrents.forEach(app.torrents.recheck) }
            Button("Ask Trackers for More Peers", systemImage: "antenna.radiowaves.left.and.right") {
                torrents.forEach(app.torrents.reannounce)
            }
            Divider()
            Button("Remove…", systemImage: "trash", role: .destructive) { app.pendingRemoval = torrents }
        }
    }
}

struct TorrentRow: View {
    @Environment(AppModel.self) private var app
    var torrent: Torrent
    @State private var isHovering = false

    private var symbol: String {
        switch torrent.phase {
        case .fetchingMetadata: "magnifyingglass"
        case .checking: "checkmark.shield"
        case .downloading: "arrow.down"
        case .seeding: "arrow.up"
        case .completed: "checkmark"
        case .paused: "pause.fill"
        case .queued: "clock"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: torrent.phase.tint, size: 38)

            VStack(alignment: .leading, spacing: 5) {
                Text(torrent.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressBar(value: torrent.phase == .fetchingMetadata ? 0 : torrent.progress, tint: torrent.phase.tint)
                Text(torrent.statusLine)
                    .font(.caption)
                    .foregroundStyle(torrent.phase == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            HStack(spacing: 2) {
                Button {
                    app.preview(torrent)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .help("Play now — works while it's still downloading")
                .disabled(!torrent.hasMetadata)

                Button {
                    app.torrents.toggle(torrent)
                } label: {
                    Image(systemName: torrent.phase == .paused || torrent.phase == .completed || torrent.phase == .error
                          ? "arrow.clockwise.circle" : "pause.circle")
                        .font(.title2)
                }
                .help(torrent.phase == .paused || torrent.phase == .completed ? "Resume" : "Pause")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0.55)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

struct AddTorrentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var folder = AppSettings.shared.downloadFolder
    @State private var isAdding = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Torrent").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Magnet link, torrent URL or info hash").font(.subheadline).foregroundStyle(.secondary)
                TextField("magnet:?xt=urn:btih:…", text: $link, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(add)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Save to").font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text((folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.directoryURL = URL(fileURLWithPath: folder)
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                Button("Choose Torrent File…") {
                    dismiss()
                    app.chooseTorrentFiles()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            focused = true
            if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.lowercased().hasPrefix("magnet:") {
                link = text
            }
        }
    }

    private func add() {
        let links = link.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !links.isEmpty else { return }
        isAdding = true
        Task {
            for entry in links {
                let text = entry.trimmingCharacters(in: .whitespaces)
                if text.lowercased().hasPrefix("magnet:") {
                    app.torrents.add(magnet: text, savePath: folder)
                } else {
                    _ = await app.torrents.add(link: text)
                }
            }
            app.selection = .transfers(.all)
            dismiss()
        }
    }
}
