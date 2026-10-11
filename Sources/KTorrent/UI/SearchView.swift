import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var sortOrder = [KeyPathComparator(\SearchResult.sortSeeders, order: .reverse)]
    @State private var selection: Set<String> = []
    @State private var added: Set<String> = []
    @State private var resolving: Set<String> = []
    @FocusState private var fieldFocused: Bool

    private var store: SearchStore { app.search }

    var body: some View {
        @Bindable var store = app.search
        let results = store.results.sorted(using: sortOrder)
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                    TextField("Search for torrents", text: $store.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .onSubmit { store.search() }
                    if store.isSearching { ProgressView().controlSize(.small) }
                    if !store.query.isEmpty {
                        Button {
                            store.query = ""
                            store.search()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.providers) { provider in
                            SourceChip(provider: provider, isPending: store.pending.contains(provider.name),
                                       failure: store.failures[provider.name]) {
                                store.setEnabled(!provider.isEnabled, for: provider.id)
                            }
                        }
                        Button {
                            app.selection = .sources
                        } label: {
                            Label("Add Source", systemImage: "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if results.isEmpty {
                if store.isSearching {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Searching \(store.pending.count) source\(store.pending.count == 1 ? "" : "s")…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "Search your sources",
                               message: "Results from every enabled source are combined into one list. Add your own sites under Sources.")
                } else if !store.failures.isEmpty && store.failures.count == store.providers.filter(\.isEnabled).count {
                    EmptyState(symbol: "wifi.exclamationmark", title: "The search couldn't be completed",
                               message: store.failures.values.first ?? "", actionTitle: "Try Again") { store.search() }
                } else {
                    EmptyState(symbol: "questionmark.circle", title: "No results",
                               message: "Nothing matched “\(store.query)”. Check the spelling or enable more sources.")
                }
            } else {
                Table(results, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.title) { result in
                        HStack(spacing: 8) {
                            Button {
                                download(result)
                            } label: {
                                if resolving.contains(result.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: added.contains(result.id) ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(added.contains(result.id) ? Color.green : Color.accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 22)
                            .help(added.contains(result.id) ? "Added to transfers" : "Download")
                            Text(result.title).lineLimit(1).truncationMode(.middle).help(result.title)
                        }
                    }
                    .width(min: 260, ideal: 460)
                    TableColumn("Size", value: \.sortSize) { result in
                        Text(result.size.map(Format.bytes) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 84)
                    TableColumn("Seeds", value: \.sortSeeders) { result in
                        Text(result.seeders.map(String.init) ?? "—").monospacedDigit()
                            .foregroundStyle((result.seeders ?? 0) > 0 ? Color.green : Color.secondary)
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Peers", value: \.sortLeechers) { result in
                        Text(result.leechers.map(String.init) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Added", value: \.sortDate) { result in
                        Text(result.date.map { Format.shortDate.string(from: $0) } ?? "—").foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("Source", value: \.provider) { result in
                        Text(result.provider).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .width(min: 80, ideal: 120)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    let chosen = results.filter { ids.contains($0.id) }
                    Button("Download", systemImage: "arrow.down.circle") { chosen.forEach(download) }
                    if let first = chosen.first {
                        if let details = first.detailsURL {
                            Button("Open Page in Browser", systemImage: "safari") { NSWorkspace.shared.open(details) }
                        }
                        if let magnet = first.magnet {
                            Button("Copy Magnet Link", systemImage: "link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(magnet, forType: .string)
                            }
                        }
                    }
                } primaryAction: { ids in
                    results.filter { ids.contains($0.id) }.forEach(download)
                }

                HStack {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    if !store.failures.isEmpty {
                        Text("·")
                        Label("\(store.failures.keys.sorted().joined(separator: ", ")) didn't respond", systemImage: "exclamationmark.triangle")
                    }
                    Spacer()
                    Text("Double-click a result to download it")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .onAppear { fieldFocused = true }
    }

    private func download(_ result: SearchResult) {
        guard !added.contains(result.id), !resolving.contains(result.id) else { return }
        resolving.insert(result.id)
        Task {
            defer { resolving.remove(result.id) }
            do {
                let link = try await SearchEngine.resolve(result)
                if await app.torrents.add(link: link) != nil { added.insert(result.id) }
            } catch {
                app.torrents.lastError = error.localizedDescription
            }
        }
    }
}

private struct SourceChip: View {
    var provider: SearchProvider
    var isPending: Bool
    var failure: String?
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                if isPending {
                    ProgressView().controlSize(.mini)
                } else if failure != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: provider.isEnabled ? "checkmark" : "circle").imageScale(.small)
                }
                Text(provider.name)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(provider.isEnabled ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(provider.isEnabled ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(failure ?? (provider.isEnabled ? "Included in searches — click to leave out" : "Not searched — click to include"))
    }
}

// MARK: - Sources

struct SourcesView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var editing: SearchProvider?

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(title: "Sources", subtitle: nil) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add Source…", systemImage: "plus")
                }
                .controlSize(.large)
            }
            Text("Sources are the sites kTorrent searches. Add any torrent site by its address and kTorrent works out how to search it, or connect a Jackett or Prowlarr indexer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            List {
                ForEach(app.search.providers) { provider in
                    HStack(spacing: 12) {
                        IconTile(symbol: symbol(for: provider.kind), tint: provider.isEnabled ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(provider.name).font(.body.weight(.medium))
                                Text(provider.isBuiltIn ? "Built in" : provider.kind.label)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            Text(provider.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if !provider.isBuiltIn {
                            Button("Edit") { editing = provider }
                                .controlSize(.small)
                        }
                        Toggle("Search \(provider.name)", isOn: Binding(
                            get: { provider.isEnabled }, set: { app.search.setEnabled($0, for: provider.id) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        if !provider.isBuiltIn {
                            Button("Edit…") { editing = provider }
                            Button("Remove", role: .destructive) { app.search.remove(provider) }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .sheet(isPresented: $showAdd) { AddSourceSheet() }
        .sheet(item: $editing) { EditSourceSheet(provider: $0) }
    }

    private func symbol(for kind: SearchProvider.Kind) -> String {
        switch kind {
        case .internetArchive: "building.columns"
        case .torznab: "server.rack"
        case .rss: "dot.radiowaves.up.forward"
        case .html: "globe"
        }
    }
}

struct AddSourceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var apiKey = ""
    @State private var testQuery = "ubuntu"
    @State private var log: [String] = []
    @State private var outcome: SiteDetector.Outcome?
    @State private var isScanning = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Source").font(.title2.weight(.semibold))
            Text("Enter a site's address. kTorrent looks for a Torznab API, an RSS feed, the site's own search description and its search form, then tests each with a sample search.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Address").gridColumnAlignment(.trailing)
                    TextField("example.org  or  https://example.org/search?q={query}", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(scan)
                }
                GridRow {
                    Text("Test search")
                    TextField("ubuntu", text: $testQuery).textFieldStyle(.roundedBorder).frame(width: 180)
                }
                GridRow {
                    Text("API key")
                    TextField("Only for Jackett, Prowlarr and other Torznab indexers", text: $apiKey).textFieldStyle(.roundedBorder)
                }
            }

            if !log.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(log.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if index == log.count - 1, isScanning {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
                            }
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let outcome {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(outcome.provider.kind.label) source found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.semibold))
                    HStack {
                        Text("Name")
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    }
                    ForEach(outcome.sample.prefix(4)) { result in
                        HStack {
                            Text(result.title).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let size = result.size { Text(Format.bytes(size)).foregroundStyle(.secondary) }
                            if let seeders = result.seeders { Text("\(seeders) seeds").foregroundStyle(.green) }
                        }
                        .font(.caption)
                        .monospacedDigit()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if let outcome {
                    Button("Add Source") {
                        var provider = outcome.provider
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty { provider.name = name }
                        app.search.add(provider)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(isScanning ? "Scanning…" : "Scan Site", action: scan)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isScanning || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func scan() {
        guard !isScanning else { return }
        isScanning = true
        outcome = nil
        log = []
        let query = testQuery.trimmingCharacters(in: .whitespaces).isEmpty ? "ubuntu" : testQuery
        Task {
            let found = await SiteDetector.detect(input: address, testQuery: query, apiKey: apiKey) { line in
                log.append(line)
                if log.count > 8 { log.removeFirst(log.count - 8) }
            }
            outcome = found
            name = found?.provider.name ?? ""
            isScanning = false
        }
    }
}

struct EditSourceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var provider: SearchProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Source").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $provider.name)
                Picker("Type", selection: $provider.kind) {
                    ForEach([SearchProvider.Kind.html, .rss, .torznab], id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Address", text: $provider.url, axis: .vertical).lineLimit(2...3)
                if provider.kind == .torznab {
                    TextField("API key", text: Binding(get: { provider.apiKey ?? "" }, set: { provider.apiKey = $0.isEmpty ? nil : $0 }))
                }
            }
            if provider.kind != .torznab {
                Text("Use {query} where the search term goes, for example https://example.org/search?q={query}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Remove Source", role: .destructive) {
                    app.search.remove(provider)
                    dismiss()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    app.search.update(provider)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}
