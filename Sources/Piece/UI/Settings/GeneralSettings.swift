import SwiftUI
import UserNotifications

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @ObservedObject private var updater = Updater.shared
    
    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Watch a folder for new torrent files", isOn: $settings.watchFolderEnabled)
                        Text("Torrent files that appear there are added automatically. A transfer you already have just gets the file's trackers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settings.watchFolderEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Folder") {
                                HStack(spacing: 8) {
                                    Label((settings.watchFolder as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                    Button("Change…") {
                                        let panel = NSOpenPanel()
                                        panel.canChooseDirectories = true
                                        panel.canChooseFiles = false
                                        if panel.runModal() == .OK, let url = panel.url { settings.watchFolder = url.path }
                                    }
                                }
                            }
                            LabeledContent("After adding") {
                                Picker("After adding", selection: $settings.watchFolderAction) {
                                    Text("Keep the file").tag(WatchFolderAction.keep)
                                    Text("Move it to the Trash").tag(WatchFolderAction.trash)
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            Toggle("Notify me when torrents are added", isOn: $settings.watchFolderNotify)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        .transition(.opacity)
                    }
                }
                .animation(.default, value: settings.watchFolderEnabled)
            }
            Section {
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
        .onChange(of: settings.watchFolderEnabled) { app.watchFolder.restart() }
        .onChange(of: settings.watchFolder) { app.watchFolder.restart() }
        .onChange(of: settings.watchFolderNotify) {
            if settings.watchFolderNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }    }
}

#Preview("General") {
    GeneralSettings()
        .environment(AppModel.shared)
        .settingsPane()
}
