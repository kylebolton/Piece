import SwiftUI

/// Compress / Pack / Unpack actions for a set of library items, for use inside context menus.
struct StorageMenu: View {
    @Environment(AppModel.self) private var app
    var itemIDs: [UUID]

    private var items: [MediaItem] { itemIDs.compactMap(app.library.item) }

    var body: some View {
        let items = items
        let packed = items.filter(\.isPacked)
        let loose = items.filter { !$0.isPacked && $0.fileExists }
        Menu {
            if !loose.isEmpty {
                Button("Compress in Place", systemImage: "arrow.down.right.and.arrow.up.left") { app.compression.compress(loose) }
                    .help("Saves space without changing the file. It stays playable.")
                Button("Pack to Save Space…", systemImage: "archivebox") { confirmPack(loose) }
            }
            if !packed.isEmpty {
                Button("Unpack", systemImage: "arrow.up.bin") { app.compression.unpack(packed) }
            }
        } label: {
            Label("Storage", systemImage: "internaldrive")
        }
        .disabled(loose.isEmpty && packed.isEmpty)
    }

    private func confirmPack(_ items: [MediaItem]) {
        let sharing = items.contains { $0.torrentHash.flatMap { app.torrents.torrent($0) } != nil }
        let alert = NSAlert()
        alert.messageText = items.count == 1 ? "Pack “\(items[0].title)”?" : "Pack \(items.count) items?"
        alert.informativeText = "The files are compressed into a checked archive and the originals are removed. "
            + "You can unpack them any time; playing one unpacks it automatically."
            + (sharing ? " Seeding for these stops." : "")
        alert.addButton(withTitle: "Pack")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { app.pack(items) }
    }
}

/// Space saved and any running jobs, shown at the bottom of the sidebar.
struct StorageSummary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let saved = app.compression.totalSaved
        if app.compression.isBusy || saved > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(app.compression.jobs) { job in
                    HStack(spacing: 6) {
                        ProgressView(value: job.progress).controlSize(.small).frame(width: 40)
                        Text("\(job.detail) \(job.title)").lineLimit(1).truncationMode(.middle)
                        Button { app.compression.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cancel")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if saved > 0 {
                    Label("Saved \(Format.bytes(saved))", systemImage: "internaldrive")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

struct StorageSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Compress finished downloads automatically", isOn: $settings.compressOnComplete)
            } header: {
                Text("Compress")
            } footer: {
                Text("Uses the Mac's built-in file compression. Files stay where they are, keep playing and keep seeding. Video and music that's already compressed barely shrinks, so Piece only rewrites files that clearly benefit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Pack items not opened for", selection: $settings.autoPackAfterDays) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                LabeledContent("Space saved") { Text(Format.bytes(app.compression.totalSaved)).monospacedDigit() }
                Button("Pack Stale Items Now") { app.packStaleItems() }
                    .disabled(settings.autoPackAfterDays == 0)
            } header: {
                Text("Pack")
            } footer: {
                Text("Packing stores a file in a smaller, checked archive and removes the original; opening it unpacks it again. Large files you're no longer sharing are packed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
