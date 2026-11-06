import SwiftUI

struct TrackerSettings: View {
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

struct TrackerRuleSection: View {
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

#Preview("Trackers") {
    TrackerSettings()
        .environment(AppModel.shared)
        .settingsPane()
}
