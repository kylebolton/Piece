import Foundation
import Security

/// One-time import of data from the app's previous names (kTorrent, then Swarmly): support folder,
/// preferences and Keychain secrets. Safe to call repeatedly; it only ever runs once per process.
enum LegacyMigration {
    private struct OldName {
        let folder: String
        let bundleID: String
        let flag: String
    }

    /// Newest first, so the most recent install wins.
    private static let oldNames = [
        OldName(folder: "Swarmly", bundleID: "me.kylebolton.swarmly", flag: "migratedFromSwarmly"),
        OldName(folder: "kTorrent", bundleID: "me.kylebolton.kTorrent", flag: "migratedFromKTorrent"),
    ]
    private static let keychainAccounts = ["openSubtitlesKey", "openSubtitlesPassword", "tmdbKey"]

    static let run: Void = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["PIECE_DEMO"] == nil else { return }
        for old in oldNames {
            moveSupportFolder(old)
            copyDefaults(old)
            moveKeychain(old)
        }
    }()

    private static func moveSupportFolder(_ old: OldName) {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldURL = base.appendingPathComponent(old.folder, isDirectory: true)
        let newURL = base.appendingPathComponent("Piece", isDirectory: true)
        guard fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: newURL.path) else { return }
        try? fm.moveItem(at: oldURL, to: newURL)
    }

    private static func copyDefaults(_ old: OldName) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: old.flag),
              let values = defaults.persistentDomain(forName: old.bundleID) else { return }
        for (key, value) in values where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: old.flag)
    }

    private static func moveKeychain(_ old: OldName) {
        for account in keychainAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: old.bundleID,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data, let value = String(data: data, encoding: .utf8) else { continue }
            if Keychain.get(account).isEmpty { Keychain.set(value, for: account) }
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: old.bundleID,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }
}
