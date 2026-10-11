import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? Self.sample : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(5 * 60))))
    }

    static let sample = WidgetSnapshot(
        downloadRate: 4_200_000, uploadRate: 380_000, activeCount: 2,
        transfers: [
            .init(id: "1", name: "Big Buck Bunny", progress: 0.64, status: "64% · 2 min left", isPaused: false),
            .init(id: "2", name: "Sintel", progress: 0.21, status: "21% · 9 min left", isPaused: false),
        ],
        recents: [
            .init(id: "a", title: "Tears of Steel", subtitle: "2012", kind: "film"),
            .init(id: "b", title: "Cosmos Laundromat", subtitle: "2015", kind: "film"),
        ],
        savedBytes: 12_400_000_000)
}

private func rate(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) + "/s"
}

/// Looks like a search field; tapping it opens Piece's search (widgets can't take typed input).
private struct SearchLink: View {
    var body: some View {
        Link(destination: URL(string: "piece://shelf")!) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Search your library")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.primary.opacity(0.08), in: Capsule())
        }
    }
}

private struct TransferRow: View {
    var transfer: WidgetSnapshot.Transfer

    var body: some View {
        Link(destination: URL(string: "piece://inspect?hash=\(transfer.id)")!) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name).font(.caption.weight(.medium)).lineLimit(1)
                ProgressView(value: transfer.progress).progressViewStyle(.linear).tint(transfer.isPaused ? .orange : .accentColor)
                Text(transfer.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct PieceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: SnapshotEntry

    var body: some View {
        let snapshot = entry.snapshot
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                Label("Piece", systemImage: "puzzlepiece.fill").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                Spacer(minLength: 0)
                Label(rate(snapshot.downloadRate), systemImage: "arrow.down").font(.callout.weight(.semibold)).monospacedDigit()
                Label(rate(snapshot.uploadRate), systemImage: "arrow.up").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(snapshot.activeCount == 0 ? "Idle" : "\(snapshot.activeCount) active").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            VStack(alignment: .leading, spacing: 8) {
                header(snapshot)
                SearchLink()
                ForEach(snapshot.transfers.prefix(2)) { TransferRow(transfer: $0) }
                if snapshot.transfers.isEmpty { Text("No transfers in progress").font(.caption).foregroundStyle(.secondary) }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                header(snapshot)
                SearchLink()
                ForEach(snapshot.transfers.prefix(4)) { TransferRow(transfer: $0) }
                if snapshot.transfers.isEmpty { Text("No transfers in progress").font(.caption).foregroundStyle(.secondary) }
                Divider()
                Text("Recently added").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(snapshot.recents.prefix(4)) { recent in
                    Link(destination: URL(string: "piece://shelf")!) {
                        HStack {
                            Text(recent.title).font(.caption).lineLimit(1)
                            Spacer()
                            Text(recent.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        HStack {
            Label("Piece", systemImage: "puzzlepiece.fill").font(.caption.weight(.semibold)).foregroundStyle(.tint)
            Spacer()
            Label(rate(snapshot.downloadRate), systemImage: "arrow.down")
            Label(rate(snapshot.uploadRate), systemImage: "arrow.up")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .labelStyle(.titleAndIcon)
    }
}

struct PieceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PieceWidget", provider: SnapshotProvider()) { entry in
            PieceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Piece")
        .description("Live speeds and transfers, with a shortcut into your library search.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct PieceWidgetBundle: WidgetBundle {
    var body: some Widget { PieceWidget() }
}
