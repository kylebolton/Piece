import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater: a background check once a day, plus "Check for Updates…" on demand.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published var canCheck = false

    private init() {
        // Not started under tests, and not at all in builds without a real public key.
        let startable = !AppPaths.isTesting && Updater.hasPublicKey
        controller = SPUStandardUpdaterController(startingUpdater: startable, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    static var hasPublicKey: Bool {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !key.isEmpty && !key.hasPrefix("PLACEHOLDER")
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
