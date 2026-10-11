import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termination: DispatchSourceSignal?
    private var dockTile: DockTileController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppPaths.isTesting else { return }
        // A SIGTERM (system shutdown, `kill`) takes the normal quit path so the search indexer service stops too.
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination?.setEventHandler { NSApp.terminate(nil) }
        termination?.resume()
        AppModel.shared.start()
        dockTile = DockTileController(store: AppModel.shared.torrents)
        dockTile?.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

@main
struct PieceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared

    var body: some Scene {
        Window("Piece", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 740)
        .commands { AppCommands(app: app) }

        Window("Player", id: "player") {
            PlayerWindow()
                .environment(app)
        }
        .defaultSize(width: 960, height: 540)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(app)
        }

        MenuBarExtra(isInserted: Bindable(app.settings).showMenuBarItem) {
            MenuBarContent()
                .environment(app)
        } label: {
            MenuBarLabel(torrents: app.torrents)
        }
    }
}

private struct MenuBarLabel: View {
    var torrents: TorrentStore

    var body: some View {
        let active = torrents.downloadRate > 0 || torrents.uploadRate > 0
        HStack(spacing: 3) {
            Image(systemName: active ? "arrow.down.circle.fill" : "arrow.down.circle")
            if torrents.downloadRate > 0 { Text(Format.rate(torrents.downloadRate)) }
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("↓ \(Format.rate(app.torrents.downloadRate))   ↑ \(Format.rate(app.torrents.uploadRate))")
        Divider()
        ForEach(app.torrents.torrents.filter { !$0.isComplete }.prefix(6)) { torrent in
            Text("\(Format.percent(torrent.progress))  \(torrent.name)")
        }
        if app.torrents.torrents.contains(where: { !$0.isComplete }) { Divider() }
        Button("Open Piece") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Add Magnet Link from Clipboard") { _ = app.addFromPasteboard() }
        Divider()
        Button("Pause All") { app.torrents.pauseAll() }
        Button("Resume All") { app.torrents.resumeAll() }
        Divider()
        Button("Quit Piece") { NSApp.terminate(nil) }
    }
}

private struct AppCommands: Commands {
    var app: AppModel
    @ObservedObject private var updater = Updater.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheck)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add Torrent…") { app.showAddSheet = true }
                .keyboardShortcut("n")
            Button("Open Torrent File…") { app.chooseTorrentFiles() }
                .keyboardShortcut("o")
            Button("Add Magnet Link from Clipboard") {
                if !app.addFromPasteboard() { app.showAddSheet = true }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandMenu("Transfers") {
            Button("Pause All") { app.torrents.pauseAll() }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Button("Resume All") { app.torrents.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Show Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i")
        }
        CommandMenu("Go") {
            Button("Transfers") { app.selection = .transfers(.all) }.keyboardShortcut("1")
            Button("Films") { app.selection = .films }.keyboardShortcut("2")
            Button("TV Shows") { app.selection = .tv }.keyboardShortcut("3")
            Button("Music") { app.selection = .music }.keyboardShortcut("4")
            Button("Search") { app.selection = .search }.keyboardShortcut("f")
            Button("Sources") { app.selection = .sources }.keyboardShortcut("5")
        }
    }
}
