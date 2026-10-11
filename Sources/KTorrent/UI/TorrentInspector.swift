import Charts
import QuickLook
import SwiftUI

struct TorrentInspector: View {
    @Environment(AppModel.self) private var app
    @State private var tab = Tab.overview

    enum Tab: String, CaseIterable {
        case overview = "Overview", files = "Files", peers = "Peers", trackers = "Trackers"
    }

    private var torrent: Torrent? {
        guard app.selectedTorrents.count == 1, let id = app.selectedTorrents.first else { return nil }
        return app.torrents.torrent(id)
    }

    var body: some View {
        if let torrent {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(torrent.name)
                        .font(.headline)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(14)

                Divider()

                switch tab {
                case .overview: OverviewTab(torrent: torrent)
                case .files: FilesTab(torrent: torrent)
                case .peers: PeersTab(torrent: torrent)
                case .trackers: TrackersTab(torrent: torrent)
                }
            }
            .id(torrent.id)
        } else {
            EmptyState(symbol: "sidebar.trailing",
                       title: app.selectedTorrents.isEmpty ? "No transfer selected" : "\(app.selectedTorrents.count) transfers selected",
                       message: "Select a single transfer to see its files, peers and trackers.")
        }
    }
}

private struct OverviewTab: View {
    @Environment(AppModel.self) private var app
    var torrent: Torrent
    @State private var pieces: [UInt8] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(torrent.phase.label).font(.subheadline.weight(.semibold)).foregroundStyle(torrent.phase.tint)
                        Spacer()
                        Text(Format.percent(torrent.progress)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                    PieceMap(pieces: pieces, tint: torrent.phase.tint)
                        .frame(height: 14)
                    if torrent.pieceCount > 0 {
                        Text("\(torrent.pieceCount) pieces of \(Format.bytes(Int64(torrent.pieceLength)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Speed").font(.subheadline.weight(.semibold))
                    Chart {
                        ForEach(Array(torrent.speedHistory.enumerated()), id: \.offset) { index, sample in
                            AreaMark(x: .value("Time", index), y: .value("Rate", sample.down), series: .value("Kind", "Down"))
                                .foregroundStyle(Color.accentColor.opacity(0.25))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Time", index), y: .value("Rate", sample.down), series: .value("Kind", "Down"))
                                .foregroundStyle(Color.accentColor)
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Time", index), y: .value("Rate", sample.up), series: .value("Kind", "Up"))
                                .foregroundStyle(.green)
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartXAxis(.hidden)
                    .chartXScale(domain: 0...119)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let rate = value.as(Int.self) { Text(Format.rate(rate)).font(.caption2) }
                            }
                        }
                    }
                    .frame(height: 96)
                    HStack(spacing: 14) {
                        Label(Format.rate(torrent.downloadRate), systemImage: "arrow.down").foregroundStyle(Color.accentColor)
                        Label(Format.rate(torrent.uploadRate), systemImage: "arrow.up").foregroundStyle(.green)
                    }
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    row("Size", Format.bytes(torrent.totalSize))
                    if torrent.totalWanted != torrent.totalSize { row("Selected", Format.bytes(torrent.totalWanted)) }
                    row("Downloaded", Format.bytes(torrent.totalWantedDone))
                    row("Uploaded", Format.bytes(torrent.totalUploaded))
                    row("Ratio", Format.ratio(uploaded: torrent.totalUploaded, downloaded: max(torrent.totalDownloaded, torrent.totalWantedDone)))
                    row("Peers", "\(torrent.peers) connected, \(torrent.seeds) seeding")
                    if let eta = torrent.etaSeconds { row("Time left", Format.eta(seconds: eta)) }
                    row("Added", Format.shortDate.string(from: torrent.dateAdded))
                    row("Location", (torrent.savePath as NSString).abbreviatingWithTildeInPath)
                    row("Info hash", torrent.id)
                }
                .font(.callout)

                HStack {
                    Button("Show in Finder") { app.torrents.revealInFinder(torrent) }
                    Button("Copy Magnet Link") {
                        guard let link = app.torrents.magnetLink(for: torrent) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: torrent.id) {
            while !Task.isCancelled {
                pieces = await app.torrents.pieceMap(for: torrent.id)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle).monospacedDigit()
        }
    }
}

/// Which parts of the torrent have arrived, squeezed into a single bar.
struct PieceMap: View {
    var pieces: [UInt8]
    var tint: Color

    var body: some View {
        Canvas { context, size in
            let background = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            context.fill(background, with: .color(.primary.opacity(0.08)))
            guard !pieces.isEmpty else { return }
            context.clip(to: background)
            let columns = max(1, Int(size.width))
            let perColumn = Double(pieces.count) / Double(columns)
            for column in 0..<columns {
                let start = Int(Double(column) * perColumn)
                let end = min(pieces.count, max(start + 1, Int(Double(column + 1) * perColumn)))
                guard start < end else { continue }
                var have = 0
                for index in start..<end where pieces[index] != 0 { have += 1 }
                guard have > 0 else { continue }
                let opacity = 0.25 + 0.75 * Double(have) / Double(end - start)
                context.fill(Path(CGRect(x: CGFloat(column), y: 0, width: 1.05, height: size.height)),
                             with: .color(tint.opacity(opacity)))
            }
        }
        .accessibilityLabel("Downloaded pieces")
    }
}

private struct FilesTab: View {
    @Environment(AppModel.self) private var app
    var torrent: Torrent
    @State private var files: [TorrentFile] = []
    @State private var quickLookURL: URL?

    var body: some View {
        Group {
            if files.isEmpty {
                EmptyState(symbol: "doc.on.doc", title: "No file list yet",
                           message: "The files appear as soon as the torrent's info has been fetched from peers.")
            } else {
                List(files) { file in
                    FileRow(file: file, torrent: torrent) { wanted in
                        app.torrents.setWanted(wanted, file: file.index, in: torrent.id)
                        if let index = files.firstIndex(where: { $0.index == file.index }) { files[index].priority = wanted ? 4 : 0 }
                    } quickLook: {
                        quickLookURL = URL(fileURLWithPath: app.torrents.absolutePath(of: file, in: torrent))
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 8))
                }
                .listStyle(.plain)
            }
        }
        .quickLookPreview($quickLookURL)
        .task(id: torrent.id) {
            while !Task.isCancelled {
                let latest = await app.torrents.files(for: torrent.id)
                if latest != files { files = latest }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct FileRow: View {
    @Environment(AppModel.self) private var app
    var file: TorrentFile
    var torrent: Torrent
    var setWanted: (Bool) -> Void
    var quickLook: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Download \(file.name)", isOn: Binding(get: { file.isWanted }, set: setWanted))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: file.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    ProgressBar(value: file.progress, tint: file.isComplete ? .green : .accentColor, height: 3)
                        .frame(width: 60)
                    Text(file.isComplete ? Format.bytes(file.size) : "\(Format.percent(file.progress)) of \(Format.bytes(file.size))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 4)
            if file.kind.isPlayable {
                Button {
                    app.play(file: file, in: torrent)
                } label: {
                    Image(systemName: "play.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(file.isComplete ? "Play" : "Play now — the rest downloads as you watch")
            } else if file.isComplete {
                Button(action: quickLook) {
                    Image(systemName: "eye").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quick Look")
            }
        }
        .opacity(file.isWanted ? 1 : 0.5)
        .help(file.path)
    }
}

private struct PeersTab: View {
    @Environment(AppModel.self) private var app
    var torrent: Torrent
    @State private var peers: [TorrentPeer] = []

    var body: some View {
        Group {
            if peers.isEmpty {
                EmptyState(symbol: "person.2", title: "No peers connected",
                           message: torrent.isPaused ? "Resume the transfer to connect to peers." : "Looking for other people sharing this torrent…")
            } else {
                List(peers) { peer in
                    HStack(spacing: 8) {
                        Image(systemName: peer.isSeed ? "arrow.up.circle.fill" : "circle.dotted")
                            .foregroundStyle(peer.isSeed ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.address).font(.callout).monospacedDigit().lineLimit(1)
                            Text(peer.client.isEmpty ? "Unknown client" : peer.client)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("↓ \(Format.rate(peer.downloadRate))")
                            Text("↑ \(Format.rate(peer.uploadRate))")
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task(id: torrent.id) {
            while !Task.isCancelled {
                peers = await app.torrents.peers(for: torrent.id).sorted { $0.downloadRate > $1.downloadRate }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct TrackersTab: View {
    @Environment(AppModel.self) private var app
    var torrent: Torrent
    @State private var trackers: [TorrentTracker] = []

    var body: some View {
        Group {
            if trackers.isEmpty {
                EmptyState(symbol: "antenna.radiowaves.left.and.right", title: "No trackers",
                           message: "This torrent finds peers through the distributed hash table (DHT) instead.")
            } else {
                List(trackers) { tracker in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tracker.working ? Color.green : (tracker.updating ? Color.orange : Color.secondary.opacity(0.5)))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tracker.host).font(.callout).lineLimit(1)
                            Text(status(of: tracker)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        if tracker.seeds >= 0 {
                            Text("\(tracker.seeds) seeds").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .help(tracker.url)
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("Ask for More Peers") { app.torrents.reannounce(torrent) }
                .controlSize(.small)
                .padding(10)
        }
        .task(id: torrent.id) {
            while !Task.isCancelled {
                trackers = await app.torrents.trackers(for: torrent.id)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func status(of tracker: TorrentTracker) -> String {
        if !tracker.message.isEmpty { return tracker.message }
        if tracker.working { return "Working" }
        return tracker.updating ? "Contacting…" : "Waiting"
    }
}
