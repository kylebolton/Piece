import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().settingsPane().tabItem { Label("General", systemImage: "gearshape") }
            NetworkSettings().settingsPane().tabItem { Label("Network", systemImage: "network") }
            TrackerSettings().settingsPane().tabItem { Label("Trackers", systemImage: "antenna.radiowaves.left.and.right") }
            SubtitleSettings().settingsPane().tabItem { Label("Subtitles", systemImage: "captions.bubble") }
            LibrarySettings().settingsPane().tabItem { Label("Library", systemImage: "books.vertical") }
            StorageSettings().settingsPane().tabItem { Label("Storage", systemImage: "internaldrive") }
        }
    }
}

private extension View {
    /// Settings tabs are grouped Forms, which scroll and so report no height of
    /// their own. Turning scrolling off and fixing the vertical size makes each
    /// tab as tall as its content, and the Settings window resizes to fit it
    /// whenever the tab changes.
    func settingsPane() -> some View {
        frame(width: 520)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
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
                .monospacedDigit()
            Text("KB/s").foregroundStyle(.secondary)
        }
    }
}

private struct TrackerSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            TrackerRuleSection(rule: .merge, title: "Auto-merge these trackers",
                               footer: "Added to every transfer, current and future, to help find more peers.")
            TrackerRuleSection(rule: .filter, title: "Always filter these trackers",
                               footer: "Removed from every transfer, current and future. A tracker can be in only one of the two lists, so adding it here takes it out of the other.")
        }
        .formStyle(.grouped)
        .onChange(of: [app.settings.trackers(.merge), app.settings.trackers(.filter)]) {
            app.torrents.applyTrackerRules(app.settings)
        }
    }
}

private struct TrackerRuleSection: View {
    @Environment(AppModel.self) private var app
    var rule: TrackerRule
    var title: String
    var footer: String

    @State private var isAdding = false
    @State private var status: String?
    @State private var isAskingForURL = false
    @State private var listURL = ""
    @State private var isFetching = false

    private var trackers: [String] { app.settings.trackers(rule) }

    var body: some View {
        Section {
            if trackers.isEmpty {
                Text("No trackers yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(trackers, id: \.self) { url in row(url) }
                    }
                }
                .scrollDisabled(false)
                .frame(height: min(CGFloat(trackers.count) * 24, 144))
            }
            HStack {
                
                Menu("Import…") {
                    Button("From File…", action: importFromFile)
                    Button("From URL…") { isAskingForURL = true }
                }
                .fixedSize()
                .disabled(isFetching)
                if isFetching { ProgressView().controlSize(.small) }
                Spacer()
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Tracker")
                .accessibilityLabel("Add Tracker")
                .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                    AddTrackerPopover { url in
                        isAdding = false
                        add(url)
                    }
                }
            }
            .alert("Import Trackers from URL", isPresented: $isAskingForURL) {
                TextField("https://example.org/trackers.txt", text: $listURL)
                Button("Import") { Task { await importFromURL() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Piece downloads the list and adds one tracker per line.")
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if !trackers.isEmpty {
                    Text("\(trackers.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ url: String) -> some View {
        HStack(spacing: 6) {
            Text(url)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                app.settings.removeTrackers([url], from: rule)
            } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(url)")
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .help(url)
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            Divider()
            Button("Remove Tracker", role: .destructive) { app.settings.removeTrackers([url], from: rule) }
            Button("Remove All Trackers", role: .destructive) { app.settings.removeTrackers(Set(trackers), from: rule) }
        }
    }

    private func add(_ url: String) {
        let result = app.settings.addTrackers([url], to: rule)
        status = result.added > 0 ? nil : "Already in the list."
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a text file with one tracker per line."
        guard panel.runModal() == .OK else { return }
        var urls: [String] = []
        for file in panel.urls {
            guard let data = try? Data(contentsOf: file) else {
                status = "Couldn't read \(file.lastPathComponent)."
                return
            }
            urls += TrackerList.parse(TrackerList.decode(data))
        }
        status = app.settings.addTrackers(urls, to: rule).summary
    }

    private func importFromURL() async {
        let text = listURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else {
            status = "Enter an http or https address."
            return
        }
        isFetching = true
        defer { isFetching = false }
        do {
            let urls = try await TrackerList.fetch(url)
            status = app.settings.addTrackers(urls, to: rule).summary
            listURL = ""
        } catch {
            status = "Couldn't download the list: \(error.localizedDescription)"
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
