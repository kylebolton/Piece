import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().settingsPane().tabItem { Label("General", systemImage: "gearshape") }
            NetworkSettings().settingsPane().tabItem { Label("Network", systemImage: "network") }
            TrackerSettings().settingsPane().tabItem { Label("Trackers", systemImage: "antenna.radiowaves.left.and.right") }
            BlocklistSettings().settingsPane().tabItem { Label("Blocklist", systemImage: "shield.lefthalf.filled") }
            SubtitleSettings().settingsPane().tabItem { Label("Subtitles", systemImage: "captions.bubble") }
            LibrarySettings().settingsPane().tabItem { Label("Library", systemImage: "books.vertical") }
            StorageSettings().settingsPane().tabItem { Label("Storage", systemImage: "internaldrive") }
        }
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(AppModel.shared)
}
