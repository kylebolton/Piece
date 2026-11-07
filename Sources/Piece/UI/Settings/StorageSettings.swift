import SwiftUI

struct StorageSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                LabeledContent("Save downloads to") {
                    HStack {
                        Text((settings.downloadFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url.path }
                        }
                    }
                }
                Toggle("Add .part to files that aren't fully downloaded", isOn: $settings.partSuffix)
                    .help("Unfinished files are named “name.part” on disk and get their real name once they finish. Playing them in Piece still works.")
            }
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
        .onChange(of: settings.partSuffix) { app.torrents.applySettings(app.settings) }
    }
}
