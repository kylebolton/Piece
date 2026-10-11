import Foundation
import Security

/// One-time import of data from the app's previous name (kTorrent): support folder,
/// preferences and Keychain secrets. Safe to call repeatedly; it only ever runs once per process.
enum LegacyMigration {
    private static let oldName = "kTorrent"
    private static let oldBundleID = "me.kylebolton.kTorrent"
    private static let keychainAccounts = ["openSubtitlesKey", "openSubtitlesPassword", "tmdbKey"]

    static let run: Void = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["SWARMLY_DEMO"] == nil else { return }
        moveSupportFolder()
        copyDefaults()
        moveKeychain()
    }()

    private static func moveSupportFolder() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent(oldName, isDirectory: true)
        let new = base.appendingPathComponent("Swarmly", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    private static func copyDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromKTorrent"),
              let old = defaults.persistentDomain(forName: oldBundleID) else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedFromKTorrent")
    }

    private static func moveKeychain() {
        for account in keychainAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: oldBundleID,
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
                kSecAttrService as String: oldBundleID,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
    }
}
