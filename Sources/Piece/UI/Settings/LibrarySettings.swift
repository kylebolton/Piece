import SwiftUI

struct LibrarySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Add finished downloads to the library", isOn: $settings.addToLibraryAutomatically)
            }
            Section {
                SecureField("API key or read access token", text: $settings.tmdbKey)
            } header: {
                Text("The Movie Database (TMDB)")
            } footer: {
                Text("A free TMDB key (themoviedb.org → Settings → API) adds posters, backdrops, descriptions, ratings and episode titles. Without one, Piece uses Apple's public catalogue, which covers fewer titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Refresh Info for Everything") {
                    app.library.refreshMetadata(for: app.library.items.filter { $0.kind != .other }.map(\.id))
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview("Library") {
    LibrarySettings()
        .environment(AppModel.shared)
        .settingsPane()
}
