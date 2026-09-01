import Foundation
import Security

struct LegacyDiscoveryResult: Equatable {
    enum Access: String {
        case accessible = "accessible"
        case unavailable = "unavailable"
    }

    let productionIdentity: Access
    let appGroup: Access
    let keychain: Access
    let accountURLPresent: Bool
    let accountAPIKeyPresent: Bool
    let customHeaderCount: Int
    let compatibleSettingCount: Int
    let feedPreferencePresent: Bool
    let playbackProgressCount: Int
    let downloadMetadataCount: Int
    let downloadFileCount: Int
    let legacyDatabase: Bool
    let legacyCache: Bool
}

enum LegacyStateDiscovery {
    static let productionBundleID = "dev.kevincfechtel.fluxNews"
    static let applicationGroup = "group.dev.kevincfechtel.fluxNews"
    static let flutterKeychainService = "flutter_secure_storage_service"

    private static let accountURLKey = "minifluxURL"
    private static let accountAPIKey = "minifluxAPIKey"
    private static let customHeaderKeyPrefix = "customHeadersKey_"
    private static let customHeaderValuePrefix = "customHeadersValue_"
    private static let feedSettingsKey = "feedSettingsOverrides"
    private static let playbackPrefix = "audio_progress_"
    private static let downloadPathPrefix = "audio_download_path_"
    private static let downloadPathByURLPrefix = "audio_download_path_url_"
    private static let downloadTimestampPrefix = "audio_download_ts_"
    private static let downloadTitlePrefix = "flux_download_title_"
    private static let downloadFeedTitlePrefix = "flux_download_feed_title_"
    private static let audioFilePrefix = "audio_"

    // This probe only reads Keychain attributes, directory entries, and file metadata.
    static func probe(fileManager: FileManager = .default,
                     homeDirectory: URL? = nil) -> LegacyDiscoveryResult {
        let isProduction = Bundle.main.bundleIdentifier == productionBundleID
        let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: applicationGroup)
        let keychainResult = keychainAccounts()
        let accounts = keychainResult.accounts
        let library = homeDirectory ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let applicationSupport = library?.appendingPathComponent("Application Support", isDirectory: true)
        let caches = library?.appendingPathComponent("Caches", isDirectory: true)
        let database = library?.appendingPathComponent("news_database.db")
        let audioCache = applicationSupport?.appendingPathComponent("audio_cache", isDirectory: true)

        return LegacyDiscoveryResult(
            productionIdentity: isProduction ? .accessible : .unavailable,
            appGroup: groupURL == nil ? .unavailable : .accessible,
            keychain: keychainResult.access,
            accountURLPresent: accounts.contains(accountURLKey),
            accountAPIKeyPresent: accounts.contains(accountAPIKey),
            customHeaderCount: Set(accounts.compactMap { key in
                if key.hasPrefix(customHeaderKeyPrefix) {
                    return String(key.dropFirst(customHeaderKeyPrefix.count))
                }
                if key.hasPrefix(customHeaderValuePrefix) {
                    return String(key.dropFirst(customHeaderValuePrefix.count))
                }
                return nil
            }).count,
            compatibleSettingCount: accounts.intersection(compatibleSettings).count,
            feedPreferencePresent: accounts.contains(feedSettingsKey),
            playbackProgressCount: accounts.filter { $0.hasPrefix(playbackPrefix) }.count,
            downloadMetadataCount: accounts.filter { key in
                downloadMetadataPrefixes.contains { key.hasPrefix($0) }
            }.count,
            downloadFileCount: countAudioFiles(in: audioCache, fileManager: fileManager),
            legacyDatabase: database.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            legacyCache: countFiles(in: caches, fileManager: fileManager) > 0
        )
    }

    static func redactedSummary(_ result: LegacyDiscoveryResult) -> [String: String] {
        [
            "Production identity": result.productionIdentity.rawValue,
            "App Group": result.appGroup.rawValue,
            "Keychain credentials": result.keychain.rawValue,
            "Base URL": result.accountURLPresent ? "present" : "absent",
            "API key": result.accountAPIKeyPresent ? "present" : "absent",
            "Custom headers": String(result.customHeaderCount),
            "Compatible settings": String(result.compatibleSettingCount),
            "Feed preferences": result.feedPreferencePresent ? "present" : "absent",
            "Playback progress": String(result.playbackProgressCount),
            "Download metadata": String(result.downloadMetadataCount),
            "Legacy downloads": String(result.downloadFileCount),
            "Legacy database": result.legacyDatabase ? "detected" : "not detected",
            "Legacy cache": result.legacyCache ? "detected" : "not detected"
        ]
    }

    private static let compatibleSettings: Set<String> = [
        "brightnessMode", "useBlackMode", "activateTruncate", "charactersToTruncate",
        "syncOnStart", "autoDownloadAudioAfterSync", "downloadAudioOnlyOnWifi",
        "deleteAudioAfterPlayback", "audioDownloadRetentionDays"
    ]

    private static let downloadMetadataPrefixes = [
        downloadPathPrefix, downloadPathByURLPrefix, downloadTimestampPrefix,
        downloadTitlePrefix, downloadFeedTitlePrefix
    ]

    private static func keychainAccounts() -> (access: LegacyDiscoveryResult.Access, accounts: Set<String>) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: flutterKeychainService,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: false
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return (.unavailable, [])
        }
        let items = (result as? [[CFString: Any]]) ?? []
        let accounts = Set(items.compactMap { $0[kSecAttrAccount] as? String })
        return (.accessible, accounts)
    }

    private static func countAudioFiles(in directory: URL?, fileManager: FileManager) -> Int {
        guard let directory, let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return entries.filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(audioFilePrefix) }.count
    }

    private static func countFiles(in directory: URL?, fileManager: FileManager) -> Int {
        guard let directory, let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.reduce(into: 0) { count, url in
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
    }
}
