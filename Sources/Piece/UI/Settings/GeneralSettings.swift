import SwiftUI

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @ObservedObject private var updater = Updater.shared
    
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
                
            }
            Section {
                Toggle("Add .part to files that aren't fully downloaded", isOn: $settings.partSuffix)
                    .help("Unfinished files are named “name.part” on disk and get their real name once they finish. Playing them in Piece still works.")
                Toggle("Notify me when a download finishes", isOn: $settings.notifyOnCompletion)
            }
            
            Section {
                Toggle("Show transfer speeds in the menu bar", isOn: $settings.showMenuBarItem)
                Toggle("Hide adult (XXX) results in search", isOn: $settings.hideAdultResults)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                .disabled(!updater.automaticallyChecks)
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.partSuffix) { app.torrents.applySettings(app.settings) }
    }
}

#Preview("General") {
    GeneralSettings()
        .environment(AppModel.shared)
        .settingsPane()
}
