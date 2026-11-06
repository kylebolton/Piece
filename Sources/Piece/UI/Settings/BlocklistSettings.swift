import SwiftUI

struct BlocklistSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let blocklist = app.blocklist
        Form {
            Section {
                Toggle("Block peers on a blocklist", isOn: $settings.blocklistEnabled)
                    .onChange(of: settings.blocklistEnabled) { blocklist.enabledChanged() }
            } footer: {
                Text("Refuses connections to and from the address ranges in the list, such as known anti-piracy monitors. Piece downloads the list once, then keeps it on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Address", text: $settings.blocklistURL, prompt: Text("https://example.org/blocklist.gz"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .disabled(blocklist.isWorking)
                    .onSubmit { Task { await blocklist.update() } }
                HStack {
                    Button("Update Now") { Task { await blocklist.update() } }
                        .disabled(blocklist.isWorking || settings.blocklistURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Import File…", action: importFile)
                        .disabled(blocklist.isWorking)
                    if blocklist.isWorking { ProgressView().controlSize(.small) }
                }
                if let message = blocklist.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(blocklist.messageIsError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Update every week automatically", isOn: $settings.blocklistAutoUpdate)
                    .disabled(settings.blocklistSource.isEmpty && settings.blocklistUpdated == nil && !settings.blocklistEnabled)
            } header: {
                Text("List")
            } footer: {
                Text("Plain text and gzip, xz, bzip2 or zip packed lists work, in PeerGuardian (.p2p), eMule (.dat) or one-range-per-line form.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let updated = settings.blocklistUpdated {
                Section("Installed") {
                    LabeledContent("Address ranges") {
                        Text(settings.blocklistRuleCount.formatted()).monospacedDigit()
                    }
                    LabeledContent("Source") {
                        Text(settings.blocklistSource)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(settings.blocklistSource)
                    }
                    LabeledContent("Updated") {
                        Text(updated.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Remove Blocklist", role: .destructive) { blocklist.remove() }
                        .disabled(blocklist.isWorking)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a blocklist: plain text, or packed as gzip, xz, bzip2 or zip."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await app.blocklist.importFile(url) }
    }
}

#Preview("Blocklist") {
    BlocklistSettings()
        .environment(AppModel.shared)
        .settingsPane()
}
