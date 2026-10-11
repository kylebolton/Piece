import Foundation
import Security

/// User preferences, persisted to UserDefaults (secrets go to the Keychain).
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var downloadFolder: String { didSet { defaults.set(downloadFolder, forKey: "downloadFolder") } }
    var listenPort: Int { didSet { defaults.set(listenPort, forKey: "listenPort") } }
    /// KB/s, 0 = unlimited
    var downloadLimitKB: Int { didSet { defaults.set(downloadLimitKB, forKey: "downloadLimitKB") } }
    var uploadLimitKB: Int { didSet { defaults.set(uploadLimitKB, forKey: "uploadLimitKB") } }
    var maxActiveDownloads: Int { didSet { defaults.set(maxActiveDownloads, forKey: "maxActiveDownloads") } }
    var maxActiveSeeds: Int { didSet { defaults.set(maxActiveSeeds, forKey: "maxActiveSeeds") } }
    var enableDHT: Bool { didSet { defaults.set(enableDHT, forKey: "enableDHT") } }
    var enablePortMapping: Bool { didSet { defaults.set(enablePortMapping, forKey: "enablePortMapping") } }
    var requireEncryption: Bool { didSet { defaults.set(requireEncryption, forKey: "requireEncryption") } }

    var addToLibraryAutomatically: Bool { didSet { defaults.set(addToLibraryAutomatically, forKey: "addToLibrary") } }
    var notifyOnCompletion: Bool { didSet { defaults.set(notifyOnCompletion, forKey: "notifyOnCompletion") } }
    /// Compress finished downloads with APFS transparent compression (stays playable in place).
    var compressOnComplete: Bool { didSet { defaults.set(compressOnComplete, forKey: "compressOnComplete") } }
    /// Pack items nobody has opened for this many days into archives; 0 = never.
    var autoPackAfterDays: Int { didSet { defaults.set(autoPackAfterDays, forKey: "autoPackAfterDays") } }
    var hideAdultResults: Bool { didSet { defaults.set(hideAdultResults, forKey: "hideAdultResults") } }
    var showMenuBarItem: Bool { didSet { defaults.set(showMenuBarItem, forKey: "showMenuBarItem") } }

    /// ISO 639-1 codes in order of preference, e.g. ["en", "es"].
    var subtitleLanguages: [String] { didSet { defaults.set(subtitleLanguages, forKey: "subtitleLanguages") } }
    var autoLoadSubtitles: Bool { didSet { defaults.set(autoLoadSubtitles, forKey: "autoLoadSubtitles") } }
    var subtitleFontScale: Double { didSet { defaults.set(subtitleFontScale, forKey: "subtitleFontScale") } }

    var openSubtitlesKey: String { didSet { Keychain.set(openSubtitlesKey, for: "openSubtitlesKey") } }
    var openSubtitlesUser: String { didSet { defaults.set(openSubtitlesUser, forKey: "openSubtitlesUser") } }
    var openSubtitlesPassword: String { didSet { Keychain.set(openSubtitlesPassword, for: "openSubtitlesPassword") } }
    var tmdbKey: String { didSet { Keychain.set(tmdbKey, for: "tmdbKey") } }

    private init() {
        LegacyMigration.run
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
        defaults.register(defaults: [
            "downloadFolder": downloads,
            "listenPort": 6881,
            "maxActiveDownloads": 5,
            "maxActiveSeeds": 5,
            "enableDHT": true,
            "enablePortMapping": true,
            "addToLibrary": true,
            "notifyOnCompletion": true,
            "showMenuBarItem": true,
            "compressOnComplete": true,
            "subtitleLanguages": [Locale.current.language.languageCode?.identifier ?? "en"],
            "autoLoadSubtitles": true,
            "subtitleFontScale": 1.0,
        ])
        downloadFolder = defaults.string(forKey: "downloadFolder") ?? downloads
        listenPort = defaults.integer(forKey: "listenPort")
        downloadLimitKB = defaults.integer(forKey: "downloadLimitKB")
        uploadLimitKB = defaults.integer(forKey: "uploadLimitKB")
        maxActiveDownloads = defaults.integer(forKey: "maxActiveDownloads")
        maxActiveSeeds = defaults.integer(forKey: "maxActiveSeeds")
        enableDHT = defaults.bool(forKey: "enableDHT")
        enablePortMapping = defaults.bool(forKey: "enablePortMapping")
        requireEncryption = defaults.bool(forKey: "requireEncryption")
        addToLibraryAutomatically = defaults.bool(forKey: "addToLibrary")
        notifyOnCompletion = defaults.bool(forKey: "notifyOnCompletion")
        showMenuBarItem = defaults.bool(forKey: "showMenuBarItem")
        compressOnComplete = defaults.bool(forKey: "compressOnComplete")
        autoPackAfterDays = defaults.integer(forKey: "autoPackAfterDays")
        hideAdultResults = defaults.bool(forKey: "hideAdultResults")
        subtitleLanguages = defaults.stringArray(forKey: "subtitleLanguages") ?? ["en"]
        autoLoadSubtitles = defaults.bool(forKey: "autoLoadSubtitles")
        subtitleFontScale = defaults.double(forKey: "subtitleFontScale")
        openSubtitlesKey = Keychain.get("openSubtitlesKey")
        openSubtitlesUser = defaults.string(forKey: "openSubtitlesUser") ?? ""
        openSubtitlesPassword = Keychain.get("openSubtitlesPassword")
        tmdbKey = Keychain.get("tmdbKey")
    }

    var sessionSettings: KTSessionSettings {
        let s = KTSessionSettings()
        s.listenPort = Int32(AppPaths.isTesting ? 0 : listenPort)
        s.downloadRateLimit = Int32(downloadLimitKB * 1024)
        s.uploadRateLimit = Int32(uploadLimitKB * 1024)
        s.maxActiveDownloads = Int32(maxActiveDownloads)
        s.maxActiveSeeds = Int32(maxActiveSeeds)
        s.enableDHT = enableDHT
        s.enableLSD = true
        s.enablePortMapping = enablePortMapping
        s.requireEncryption = requireEncryption
        return s
    }
}

enum Keychain {
    private static let service = "me.kylebolton.piece"

    static func get(_ key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
