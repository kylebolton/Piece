import AppKit
import Observation

/// Draws live download and upload speeds on the Dock icon. Works with the main window closed,
/// and reverts to the plain app icon when nothing is transferring.
@MainActor
final class DockTileController {
    private let store: TorrentStore
    private let tileView = DockTileView()

    init(store: TorrentStore) {
        self.store = store
    }

    func start() {
        update()
    }

    private func update() {
        let (down, up) = withObservationTracking {
            (store.downloadRate, store.uploadRate)
        } onChange: { [weak self] in
            // onChange fires before the new value lands, so read again on the next main-actor turn.
            Task { @MainActor in self?.update() }
        }
        let tile = NSApp.dockTile
        if down <= 0, up <= 0 {
            guard tile.contentView != nil else { return }
            tile.contentView = nil
        } else {
            let lines = [(down > 0 ? "↓ \(Format.rate(down))" : nil), (up > 0 ? "↑ \(Format.rate(up))" : nil)].compactMap { $0 }
            guard tileView.lines != lines || tile.contentView == nil else { return }
            tileView.lines = lines
            tile.contentView = tileView
        }
        tile.display()
    }
}

private final class DockTileView: NSView {
    var lines: [String] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        guard !lines.isEmpty else { return }

        // Big enough to read at Dock size: start large, then shrink until the widest line fits the tile.
        let maxWidth = bounds.width * 0.9
        var fontSize = bounds.width * 0.21
        var font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        func textWidth(_ font: NSFont) -> CGFloat {
            lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        }
        while textWidth(font) + fontSize * 1.2 > maxWidth, fontSize > 8 {
            fontSize -= 1
            font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let rowHeight = fontSize * 1.3
        let width = textWidth(font) + fontSize * 1.2
        let height = rowHeight * CGFloat(lines.count) + fontSize * 0.4
        let pill = NSRect(x: (bounds.width - width) / 2, y: bounds.height * 0.08, width: width, height: height)

        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: pill, xRadius: height / 2.2, yRadius: height / 2.2).fill()

        for (index, line) in lines.enumerated() {
            let size = (line as NSString).size(withAttributes: attributes)
            let y = pill.maxY - fontSize * 0.2 - rowHeight * CGFloat(index + 1) + (rowHeight - size.height) / 2
            (line as NSString).draw(at: NSPoint(x: pill.midX - size.width / 2, y: y), withAttributes: attributes)
        }
    }
}
