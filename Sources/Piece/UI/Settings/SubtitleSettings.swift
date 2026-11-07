import SwiftUI

struct SubtitleSettings: View {
    @Environment(AppModel.self) private var app
    @State private var isAddingLanguage = false
    @State private var dropTarget: String?
    @State private var isEditingStyle = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle(isOn: $settings.autoLoadSubtitles) {
                    Text("Load subtitles automatically")
                    Text("From the download, inside the video, then OpenSubtitles.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        SubtitleStyleSwatch(style: settings.subtitleStyle)
                        Button("Customize…") { isEditingStyle = true }
                            .semitransientPopover(isPresented: $isEditingStyle) {
                                SubtitleStyleEditor(settings: app.settings)
                            }
                    }
                } label: {
                    Text("Appearance")
                    Text(styleSummary(settings.subtitleStyle))
                }
            }
            languagesSection
            Section {
                SecureField("API key", text: $settings.openSubtitlesKey,
                            prompt: Text(BuiltInKeys.openSubtitles.isEmpty ? "Needed to search online" : "Optional"))
                LabeledContent("Account") {
                    HStack(spacing: 6) {
                        TextField("Username", text: $settings.openSubtitlesUser, prompt: Text("Username"))
                            .textContentType(.username)
                        SecureField("Password", text: $settings.openSubtitlesPassword, prompt: Text("Password"))
                            .textContentType(.password)
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 260)
                }
            } header: {
                Text("OpenSubtitles")
            } footer: {
                Text("Get a free API key at [opensubtitles.com](https://www.opensubtitles.com/en/consumers) (Profile → API consumers). The account is optional and raises the daily download limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// "System Semibold · 100% · White"
    private func styleSummary(_ style: SubtitleStyle) -> String {
        [style.fontDescription,
         style.scale.formatted(.percent.precision(.fractionLength(0))),
         String(localized: style.color.title)].joined(separator: " · ")
    }

    // MARK: - Preferred languages

    private var languagesSection: some View {
        let codes = app.settings.subtitleLanguages
        return Section {
            ForEach(Array(codes.enumerated()), id: \.element) { index, code in
                if let language = SubtitleLanguage[code] {
                    PreferredLanguageRow(
                        rank: index + 1,
                        language: language,
                        coveredBy: language.family.flatMap { family in
                            codes[..<index].contains(family) ? SubtitleLanguage[family] : nil
                        },
                        isLast: index == codes.count - 1,
                        canReorder: codes.count > 1,
                        isDropTarget: dropTarget == code,
                        move: { destination in _ = move(code, to: destination) },
                        remove: { remove(code) })
                    .draggable(code) {
                        Text(language.preferenceName)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first else { return false }
                        return move(dragged, to: index)
                    } isTargeted: { isTargeted in
                        if isTargeted { dropTarget = code } else if dropTarget == code { dropTarget = nil }
                    }
                }
            }
        } header: {
            HStack {
                Text("Preferred Languages")
                Spacer()
                Button("Add Language…") { isAddingLanguage = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .popover(isPresented: $isAddingLanguage, arrowEdge: .bottom) {
                        SubtitleLanguagePicker(chosen: codes) { add($0) }
                    }
            }
        } footer: {
            Text(languagesFooter(codes))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func languagesFooter(_ codes: [String]) -> String {
        let order = codes.count > 1 ? "First found wins; drag to reorder. " : ""
        guard let family = codes.lazy.compactMap({ SubtitleLanguage[$0]?.family }).first.flatMap({ SubtitleLanguage[$0] }) else {
            return order + "Variants like Portuguese (Portugal) and (Brazil) are kept apart."
        }
        return order + "Variants are kept apart; one labeled just “\(family.name)” comes after every exact match."
    }

    private func add(_ language: SubtitleLanguage) {
        isAddingLanguage = false
        guard !app.settings.subtitleLanguages.contains(language.id) else { return }
        withAnimation { app.settings.subtitleLanguages.append(language.id) }
    }

    private func remove(_ code: String) {
        guard app.settings.subtitleLanguages.count > 1 else { return }
        withAnimation { app.settings.subtitleLanguages.removeAll { $0 == code } }
    }

    /// Puts `code` at `destination`, so a language dropped on another row takes its place.
    @discardableResult
    private func move(_ code: String, to destination: Int) -> Bool {
        var codes = app.settings.subtitleLanguages
        guard let source = codes.firstIndex(of: code), source != destination, codes.indices.contains(destination) else {
            return false
        }
        codes.remove(at: source)
        codes.insert(code, at: destination)
        withAnimation { app.settings.subtitleLanguages = codes }
        return true
    }
}

// MARK: - Rows

private struct PreferredLanguageRow: View {
    var rank: Int
    var language: SubtitleLanguage
    /// A family earlier in the list that already accepts this variant.
    var coveredBy: SubtitleLanguage?
    var isLast: Bool
    /// More than one language, so rows can move and be removed.
    var canReorder: Bool
    var isDropTarget: Bool
    var move: (Int) -> Void
    var remove: () -> Void

    private var detail: String? {
        if let coveredBy { return "Already accepted by \(coveredBy.preferenceName) above" }
        return language.note
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(rank, format: .number)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(language.preferenceName)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if canReorder {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help("Drag to change the order")
                    .accessibilityHidden(true)
            }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!canReorder)
            .help(canReorder ? "Remove \(language.preferenceName)" : "Keep at least one language")
            .accessibilityLabel("Remove \(language.preferenceName)")
        }
        .contentShape(Rectangle())
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.15))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            }
        }
        .contextMenu {
            Button("Move to Top") { move(0) }.disabled(rank == 1)
            Button("Move Up") { move(rank - 2) }.disabled(rank == 1)
            Button("Move Down") { move(rank) }.disabled(isLast)
            Divider()
            Button("Remove", role: .destructive, action: remove).disabled(!canReorder)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rank). \(language.preferenceName)")
        .accessibilityAction(named: "Move Up") { if rank > 1 { move(rank - 2) } }
        .accessibilityAction(named: "Move Down") { if !isLast { move(rank) } }
    }
}

// MARK: - Language picker

struct SubtitleLanguagePicker: View {
    var chosen: [String]
    var onPick: (SubtitleLanguage) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var isSearchFocused: Bool

    private struct Entry: Identifiable {
        var key: String
        var language: SubtitleLanguage
        var id: String { key }
    }

    private static let alphabetical = SubtitleLanguage.all.sorted {
        $0.preferenceName.localizedStandardCompare($1.preferenceName) == .orderedAscending
    }

    /// The system's languages and, for a regional variant, its whole family.
    private var suggested: [SubtitleLanguage] {
        var ids: [String] = []
        for id in SubtitleLanguage.defaultPreferences() {
            for candidate in [id, SubtitleLanguage[id]?.family].compactMap({ $0 }) where !ids.contains(candidate) {
                ids.append(candidate)
            }
        }
        return ids.filter { !chosen.contains($0) }.compactMap { SubtitleLanguage[$0] }
    }

    private var sections: [(title: String?, entries: [Entry])] {
        let folded = SubtitleLanguage.fold(query)
        guard folded.isEmpty else {
            let matches = Self.alphabetical.compactMap { language in language.score(for: folded).map { (language, $0) } }
            return [(nil, matches.sorted { $0.1 < $1.1 }.map { Entry(key: $0.0.id, language: $0.0) })]
        }
        let all = Self.alphabetical.map { Entry(key: "all:\($0.id)", language: $0) }
        let suggested = suggested.map { Entry(key: "suggested:\($0.id)", language: $0) }
        return suggested.isEmpty ? [(nil, all)] : [("Suggested", suggested), ("All Languages", all)]
    }

    /// Rows Return and the arrow keys can land on.
    private var selectable: [Entry] {
        sections.flatMap(\.entries).filter { !chosen.contains($0.language.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search languages", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit(pickHighlighted)
                    .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(sections, id: \.title) { section in
                        if let title = section.title {
                            Section(title) { rows(section.entries) }
                        } else {
                            rows(section.entries)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if sections.allSatisfy(\.entries.isEmpty) { ContentUnavailableView.search(text: query) }
                }
                .onChange(of: highlighted) {
                    if let highlighted { proxy.scrollTo(highlighted) }
                }
            }
        }
        .frame(width: 340, height: 420)
        .onAppear {
            isSearchFocused = true
            highlighted = selectable.first?.key
        }
        .onChange(of: query) { highlighted = selectable.first?.key }
    }

    private func rows(_ entries: [Entry]) -> some View {
        ForEach(entries) { entry in
            let language = entry.language
            let isChosen = chosen.contains(language.id)
            Button {
                onPick(language)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(language.preferenceName)
                        if let note = language.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if let native = language.nativeName, SubtitleLanguage.fold(native) != SubtitleLanguage.fold(language.name) {
                        Text(native)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if isChosen {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Already in your list")
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isChosen)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 5)
                    .fill(entry.key == highlighted ? Color.accentColor.opacity(0.2) : .clear)
                    .padding(.horizontal, 6))
            .listRowSeparator(.hidden)
            .onHover { if $0, !isChosen { highlighted = entry.key } }
            .id(entry.key)
        }
    }

    private func moveHighlight(by offset: Int) {
        let keys = selectable.map(\.key)
        guard !keys.isEmpty else { return }
        let current = highlighted.flatMap { keys.firstIndex(of: $0) } ?? (offset > 0 ? -1 : keys.count)
        highlighted = keys[min(max(current + offset, 0), keys.count - 1)]
    }

    private func pickHighlighted() {
        let entries = selectable
        if let entry = entries.first(where: { $0.key == highlighted }) ?? entries.first { onPick(entry.language) }
    }
}

private extension SubtitleLanguage {
    /// Lower is better: exact code, then a name that starts with the query, then one that contains it.
    func score(for folded: String) -> Int? {
        let codes = ([id, tag] + aliases).map(SubtitleLanguage.fold)
        if codes.contains(folded) { return 0 }
        let names = [preferenceName, nativeName, Locale.current.localizedString(forIdentifier: tag), note]
            .compactMap { $0 }.map(SubtitleLanguage.fold)
        if names.contains(where: { $0.hasPrefix(folded) }) { return 1 }
        if names.contains(where: { $0.contains(folded) }) || codes.contains(where: { $0.hasPrefix(folded) }) { return 2 }
        return nil
    }
}

#Preview("Subtitles") {
    SubtitleSettings()
        .environment(AppModel.shared)
        .settingsPane()
}

#Preview("Add Language") {
    SubtitleLanguagePicker(chosen: ["pt-pt", "en"]) { _ in }
}
