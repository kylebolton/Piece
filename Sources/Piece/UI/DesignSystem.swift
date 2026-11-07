import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

extension TorrentPhase {
    var tint: Color {
        switch self {
        case .downloading, .fetchingMetadata: .accentColor
        case .seeding, .completed: .green
        case .checking, .held: .orange
        case .paused, .queued: .secondary
        case .error: .red
        }
    }
}

/// Thin rounded progress bar used throughout the app.
struct ProgressBar: View {
    var value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, proxy.size.width * min(max(value, 0), 1)))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: value)
        .accessibilityElement()
        .accessibilityValue(Format.percent(value))
    }
}

/// Rounded tile with an SF Symbol, used as the leading icon in rows.
struct IconTile: View {
    var symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(tint.opacity(0.12))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.large)
                    .liquidGlassButtonStyle(prominent: true)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Artwork

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL, maxPixel: CGFloat) async -> NSImage? {
        if let cached = image(for: url) { return cached }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Poster or cover art loaded from the artwork cache, with a tinted placeholder.
struct ArtworkView: View {
    var url: URL?
    var symbol: String
    var cornerRadius: CGFloat = 8
    var maxPixel: CGFloat = 600

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = ImageCache.shared.image(for: url)
            if image == nil { image = await ImageCache.shared.load(url, maxPixel: maxPixel) }
        }
    }
}

// MARK: - AirPlay

/// The system AirPlay button, bound to one of the app's players.
struct AirPlayButton: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}

/// Header shared by the library and search screens: large title, count, trailing controls.
struct ContentHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.title.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct FilterField: View {
    @Binding var text: String
    var prompt = "Filter"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .liquidGlassEffect(type: .field)
        .frame(width: 190)
    }
}

// MARK: - Liquid Glass

/// Where a Liquid Glass surface sits. On macOS 26 every case is glass; on earlier
/// systems each falls back to the look the app had before.
enum LiquidGlassModifierType {
    /// Search and filter fields. Falls back to a faint fill.
    case field
    /// Toggleable pills, tinted when on. Falls back to a tinted or faint fill.
    case chip(tint: Color?)
    /// Controls and notices floating over video. Falls back to a material.
    case overlay
    /// Badges and buttons on top of artwork. Falls back to a dark scrim.
    case scrim(opacity: Double)
    /// Larger floating panels. Falls back to a material.
    case card(cornerRadius: CGFloat)
}

struct LiquidGlassModifier: ViewModifier {
    var type: LiquidGlassModifierType
    var interactive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content.background(fallback, in: shape)
        }
    }

    private var shape: AnyShape {
        switch type {
        case .card(let radius): AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        default: AnyShape(Capsule())
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if case .chip(let tint?) = type { glass = glass.tint(tint.opacity(0.3)) }
        return interactive ? glass.interactive() : glass
    }

    private var fallback: AnyShapeStyle {
        switch type {
        case .field: AnyShapeStyle(.primary.opacity(0.06))
        case .chip(let tint): AnyShapeStyle(tint.map { $0.opacity(0.16) } ?? .primary.opacity(0.06))
        case .overlay, .card: AnyShapeStyle(.ultraThinMaterial)
        case .scrim(let opacity): AnyShapeStyle(.black.opacity(opacity))
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26, the app's earlier look on older systems.
    /// `interactive` makes the glass react to the pointer; use it on clickable surfaces.
    func liquidGlassEffect(type: LiquidGlassModifierType, interactive: Bool = false) -> some View {
        modifier(LiquidGlassModifier(type: type, interactive: interactive))
    }

    /// On macOS 26, mirrors this background under the floating sidebar and inspector
    /// so the window reads as one surface. Does nothing on older systems.
    @ViewBuilder
    func liquidGlassBackgroundExtension() -> some View {
        if #available(macOS 26.0, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }

    /// Glass buttons on macOS 26, bordered buttons on older systems.
    @ViewBuilder
    func liquidGlassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
    
    /// Allow to hide or not the View with a Bool
    @ViewBuilder
    func isHidden(_ hidden: Bool) -> some View {
        if hidden {
            self.hidden()
        } else {
            self
        }
    }
}

/// The icon Finder shows for a torrent's download, with its status as a small badge.
struct TorrentIcon: View {
    var torrent: Torrent
    var symbol: String
    var size: CGFloat = 32

    @State private var icon: NSImage?

    /// Changes whenever the item on disk may have changed kind or name (created, renamed from `.part`).
    private var lookupKey: String {
        "\(torrent.savePath)/\(torrent.name)|\(torrent.hasMetadata)|\(torrent.isComplete)"
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            let badge = size * 0.5
            Image(systemName: symbol)
                .font(.system(size: badge * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: badge, height: badge)
                .background(torrent.phase.badgeColor, in: Circle())
                .padding(1.5)
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .offset(x: badge * 0.2, y: badge * 0.15)
        }
        .task(id: lookupKey) { icon = FileIcon.forTorrent(torrent) }
    }
}

enum FileIcon {
    /// What Finder shows for the torrent's top-level item. While it is still downloading
    /// (as `name.part`) or not on disk yet, falls back to the icon for its type.
    static func forTorrent(_ torrent: Torrent) -> NSImage {
        let final = (torrent.savePath as NSString).appendingPathComponent(torrent.name)
        if FileManager.default.fileExists(atPath: final) { return NSWorkspace.shared.icon(forFile: final) }
        if let type = UTType(filenameExtension: (torrent.name as NSString).pathExtension), type.isDeclared {
            return NSWorkspace.shared.icon(for: type)
        }
        // A multi-file torrent is saved as a folder named after it.
        return NSWorkspace.shared.icon(for: torrent.hasMetadata ? .folder : .data)
    }
}

extension TorrentPhase {
    /// Opaque version of `tint`, readable as a filled badge.
    var badgeColor: Color {
        switch self {
        case .paused, .queued: .gray
        default: tint
        }
    }
}
