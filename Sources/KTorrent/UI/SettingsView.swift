import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
            SubtitleSettings().tabItem { Label("Subtitles", systemImage: "captions.bubble") }
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        @Bindable var settings = app.settings
        Form {
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
            Toggle("Notify me when a download finishes", isOn: $settings.notifyOnCompletion)
            Toggle("Show transfer speeds in the menu bar", isOn: $settings.showMenuBarItem)
            Toggle("Hide adult (XXX) results in search", isOn: $settings.hideAdultResults)
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
    }
}

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Speed limits") {
                LabeledContent("Download") { limitField($settings.downloadLimitKB) }
                LabeledContent("Upload") { limitField($settings.uploadLimitKB) }
            }
            Section("Queue") {
                Stepper("Download up to \(settings.maxActiveDownloads) at once", value: $settings.maxActiveDownloads, in: 1...50)
                Stepper("Seed up to \(settings.maxActiveSeeds) at once", value: $settings.maxActiveSeeds, in: 0...100)
            }
            Section("Connection") {
                LabeledContent("Incoming port") {
                    TextField("Port", value: $settings.listenPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Open the port on my router automatically (UPnP / NAT-PMP)", isOn: $settings.enablePortMapping)
                Toggle("Find peers without trackers (DHT)", isOn: $settings.enableDHT)
                Toggle("Only connect to peers that support encryption", isOn: $settings.requireEncryption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settingsFingerprint) { app.torrents.applySettings(app.settings) }
    }

    private var settingsFingerprint: [Int] {
        let s = app.settings
        return [s.downloadLimitKB, s.uploadLimitKB, s.maxActiveDownloads, s.maxActiveSeeds, s.listenPort,
                s.enablePortMapping ? 1 : 0, s.enableDHT ? 1 : 0, s.requireEncryption ? 1 : 0]
    }

    private func limitField(_ value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            TextField("Unlimited", value: Binding(get: { value.wrappedValue == 0 ? nil : value.wrappedValue },
                                                   set: { value.wrappedValue = max(0, $0 ?? 0) }),
                      format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
            Text("KB/s").foregroundStyle(.secondary)
        }
    }
}

private struct SubtitleSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Load matching subtitles automatically", isOn: $settings.autoLoadSubtitles)
                LabeledContent("Preferred languages") {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(Array(settings.subtitleLanguages.enumerated()), id: \.element) { index, code in
                            HStack {
                                Text("\(index + 1). \(SubtitleLanguage.name(for: code) ?? code)")
                                Button {
                                    settings.subtitleLanguages.removeAll { $0 == code }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(settings.subtitleLanguages.count <= 1)
                                .accessibilityLabel("Remove \(SubtitleLanguage.name(for: code) ?? code)")
                            }
                        }
                        Menu("Add Language") {
                            ForEach(SubtitleLanguage.all.filter { !settings.subtitleLanguages.contains($0.code) }, id: \.code) { language in
                                Button(language.name) { settings.subtitleLanguages.append(language.code) }
                            }
                        }
                        .fixedSize()
                    }
                }
                LabeledContent("Text size") {
                    Slider(value: $settings.subtitleFontScale, in: 0.6...1.8) {
                        Text("Text size")
                    } minimumValueLabel: {
                        Text("A").font(.caption)
                    } maximumValueLabel: {
                        Text("A").font(.title3)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            Section {
                SecureField("API key", text: $settings.openSubtitlesKey)
                TextField("Username (optional)", text: $settings.openSubtitlesUser)
                SecureField("Password (optional)", text: $settings.openSubtitlesPassword)
            } header: {
                Text("OpenSubtitles")
            } footer: {
                Text("Subtitles inside a download are matched without an account. To search online, create a free API key at opensubtitles.com (Profile → API consumers). Signing in raises the daily download limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LibrarySettings: View {
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
                Text("A free TMDB key (themoviedb.org → Settings → API) adds posters, backdrops, descriptions, ratings and episode titles. Without one, kTorrent uses Apple's public catalogue, which covers fewer titles.")
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
