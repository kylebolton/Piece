import SwiftUI

/// A small coloured label for a tag.
struct TagChip: View {
    var tag: Tag
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tag.color).frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            Text(tag.name).lineLimit(1)
        }
        .font(compact ? .caption2 : .caption)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 1.5 : 2.5)
        .background(tag.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tag.color.opacity(0.3), lineWidth: 0.5))
        .accessibilityLabel("Tag \(tag.name)")
    }
}

/// Chips for whichever tags a target has, capped so a row never grows.
struct TagChips: View {
    @Environment(AppModel.self) private var app
    var target: String
    var limit = 3

    var body: some View {
        let tags = app.tags.tags(for: target)
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(limit)) { TagChip(tag: $0, compact: true) }
                if tags.count > limit { Text("+\(tags.count - limit)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Toggle-style menu items for assigning tags, used inside context menus.
struct TagMenu: View {
    @Environment(AppModel.self) private var app
    var targets: [String]
    @State private var newName = ""

    var body: some View {
        Menu {
            ForEach(app.tags.tags) { tag in
                let on = targets.allSatisfy { app.tags.has(tag, on: $0) }
                Button {
                    app.tags.toggle(tag, on: targets)
                } label: {
                    Label(tag.name, systemImage: on ? "checkmark.circle.fill" : "circle")
                }
            }
            if !app.tags.tags.isEmpty { Divider() }
            Button("New Tag…", systemImage: "plus") {
                if let name = TagPrompt.ask(), let tag = app.tags.create(name: name) { app.tags.assign(tag, to: targets) }
            }
        } label: {
            Label("Tags", systemImage: "tag")
        }
    }
}

enum TagPrompt {
    /// Asks for a tag name with a small modal alert.
    @MainActor
    static func ask(title: String = "New Tag", initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Tags help you group and find things. Search with #name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        field.placeholderString = "Tag name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// A popover for tagging the given targets, with inline creation.
struct TagPickerButton: View {
    @Environment(AppModel.self) private var app
    var targets: [String]
    @State private var open = false
    @State private var draft = ""

    var body: some View {
        Button { open.toggle() } label: { Label("Tags", systemImage: "tag") }
            .help("Add or remove tags")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if app.tags.tags.isEmpty {
                        Text("No tags yet — type a name below.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(app.tags.tags) { tag in
                        let on = targets.allSatisfy { app.tags.has(tag, on: $0) }
                        Button { app.tags.toggle(tag, on: targets) } label: {
                            HStack {
                                TagChip(tag: tag)
                                Spacer()
                                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Divider()
                    TextField("New tag", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let tag = app.tags.create(name: draft) { app.tags.assign(tag, to: targets) }
                            draft = ""
                        }
                }
                .padding(12)
                .frame(width: 230)
            }
            .disabled(targets.isEmpty)
    }
}

/// A tag's page: its films, shows and albums on the shelf, with any tagged transfers above.
struct TagPageView: View {
    @Environment(AppModel.self) private var app
    var tagID: UUID

    var body: some View {
        if let tag = app.tags.tag(tagID) {
            let tagged = app.tags.targets(with: tag)
            let torrents = app.torrents.torrents.filter { tagged.contains($0.id) }
            VStack(spacing: 0) {
                if !torrents.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(torrents) { TorrentRow(torrent: $0).padding(.horizontal, 14) }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
                ShelfView(tag: tag)
            }
        } else {
            EmptyState(symbol: "tag", title: "Tag not found", message: "This tag was deleted.")
        }
    }
}
