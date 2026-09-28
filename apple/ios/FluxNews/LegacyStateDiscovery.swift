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

struct LegacyAccountImport: Equatable {
    struct Header: Equatable {
        let name: String
        let value: String
    }

    let serverURL: String
    let apiKey: String
    let customHeaders: [Header]
}

struct LegacyPlaybackProgressImport: Equatable {
    let articleID: Int64
    let positionMs: UInt64
}

struct LegacyDownloadImport: Equatable {
    let enclosureID: Int64
    let sourceFile: URL
}

struct LegacyFeedOpenInMinifluxImport: Equatable {
    let feedID: Int64
    let openInMiniflux: Bool
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
    private static let flutterPreferencesPrefix = "flutter."
    private static let downloadPathPrefix = "audio_download_path_"
    private static let downloadPathByURLPrefix = "audio_download_path_url_"
    private static let downloadTimestampPrefix = "audio_download_ts_"
    private static let downloadTitlePrefix = "flux_download_title_"
    private static let downloadFeedTitlePrefix = "flux_download_feed_title_"
    private static let audioFilePrefix = "audio_"

    // This probe only reads Keychain attributes, Flutter UserDefaults values,
    // directory entries, and file metadata.
    static func probe(fileManager: FileManager = .default,
                     homeDirectory: URL? = nil) -> LegacyDiscoveryResult {
        let isProduction = Bundle.main.bundleIdentifier == productionBundleID
        let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: applicationGroup)
        let keychainResult = keychainAccounts()
        let accounts = keychainResult.accounts
        let sharedPlayback = parseFlutterSharedPreferencesPlaybackImports(
            stringValues(UserDefaults.standard.dictionaryRepresentation())
        )
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
            compatibleSettingCount: accounts.intersection(auditedSettings).count,
            feedPreferencePresent: accounts.contains(feedSettingsKey),
            playbackProgressCount: Set(sharedPlayback.map(\.articleID)).union(
                accounts.compactMap(playbackArticleID)
            ).count,
            downloadMetadataCount: accounts.filter { key in
                downloadMetadataPrefixes.contains { key.hasPrefix($0) }
            }.count,
            downloadFileCount: countAudioFiles(in: audioCache, fileManager: fileManager),
            legacyDatabase: database.map { fileManager.fileExists(atPath: $0.path) } ?? false,
            legacyCache: countFiles(in: caches, fileManager: fileManager) > 0
        )
    }

    /// Reads only the legacy Flutter secure-storage namespace and returns the
    /// account material that has a direct native equivalent. This is a source
    /// reader for the D9 copy/import migration; it never writes to Keychain,
    /// native storage, Core storage, or the legacy store.
    static func readAccountImport() -> LegacyAccountImport? {
        guard Bundle.main.bundleIdentifier == productionBundleID else { return nil }
        guard let values = keychainValues() else { return nil }
        return parseAccountImport(values)
    }

    /// Reads only the four retained media policy values from the same Flutter
    /// secure-storage namespace as account import. It never mutates Keychain.
    static func readMediaSettingsImport() -> IOSLegacyMediaSettingsImport? {
        guard Bundle.main.bundleIdentifier == productionBundleID,
              let values = keychainValues() else { return nil }
        let mediaValues = values.filter { compatibleMediaSettings.contains($0.key) }
        return IOSLegacyMediaSettingsImport.parse(mediaValues)
    }

    /// Reads only positive per-feed Open in Miniflux overrides from Flutter's
    /// secure storage. Flutter persisted default zero values for every field,
    /// so zero is not evidence of an explicit user choice.
    static func readFeedOpenInMinifluxImports() -> [LegacyFeedOpenInMinifluxImport]? {
        guard Bundle.main.bundleIdentifier == productionBundleID,
              let values = keychainValues() else { return nil }
        return parseFeedOpenInMinifluxImports(values[feedSettingsKey])
    }

    /// Reads Flutter's article-keyed playback values with the same source
    /// priority as Flutter: SharedPreferences first, then Keychain per missing
    /// article ID. It never modifies either legacy store.
    static func readPlaybackProgressImports() -> [LegacyPlaybackProgressImport]? {
        guard Bundle.main.bundleIdentifier == productionBundleID else { return nil }
        let shared = parseFlutterSharedPreferencesPlaybackImports(
            stringValues(UserDefaults.standard.dictionaryRepresentation())
        )
        guard let keychain = keychainValues() else {
            return shared.isEmpty ? nil : shared
        }
        return mergePlaybackProgressImports(
            sharedPreferences: shared,
            keychain: parsePlaybackProgressImports(keychain)
        )
    }

    /// Reads only primary attachment-ID download paths. URL-keyed values and
    /// filenames are not identity evidence and are intentionally ignored.
    static func readDownloadImports(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> [LegacyDownloadImport]? {
        guard Bundle.main.bundleIdentifier == productionBundleID,
              let values = keychainValues() else { return nil }
        let library = homeDirectory ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        guard let audioCache = library?.appendingPathComponent("Application Support/audio_cache", isDirectory: true) else {
            return nil
        }
        return parseDownloadImports(values, audioCache: audioCache, fileManager: fileManager)
    }

    /// Pure decoder kept separate from Keychain access so migration semantics can
    /// be regression-tested without creating or mutating legacy credentials.
    static func parseAccountImport(_ values: [String: String]) -> LegacyAccountImport? {
        guard let rawServer = values[accountURLKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawServer.isEmpty,
              let rawAPIKey = values[accountAPIKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAPIKey.isEmpty else {
            return nil
        }

        let headerIDs = Set(values.keys.compactMap { key -> String? in
            if key.hasPrefix(customHeaderKeyPrefix) {
                return String(key.dropFirst(customHeaderKeyPrefix.count))
            }
            if key.hasPrefix(customHeaderValuePrefix) {
                return String(key.dropFirst(customHeaderValuePrefix.count))
            }
            return nil
        })

        let headers = headerIDs.sorted().compactMap { id -> LegacyAccountImport.Header? in
            guard let rawName = values[customHeaderKeyPrefix + id],
                  let rawValue = values[customHeaderValuePrefix + id] else {
                return nil
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return .init(name: name, value: rawValue)
        }

        return LegacyAccountImport(
            serverURL: rawServer,
            apiKey: rawAPIKey,
            customHeaders: headers
        )
    }

    static func parsePlaybackProgressImports(
        _ values: [String: String]
    ) -> [LegacyPlaybackProgressImport] {
        values.compactMap { key, value in
            guard key.hasPrefix(playbackPrefix),
                  let articleID = Int64(key.dropFirst(playbackPrefix.count)),
                  articleID > 0,
                  let positionMs = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return LegacyPlaybackProgressImport(articleID: articleID, positionMs: positionMs)
        }
        .sorted { $0.articleID < $1.articleID }
    }

    static func parseFlutterSharedPreferencesPlaybackImports(
        _ values: [String: String]
    ) -> [LegacyPlaybackProgressImport] {
        values.compactMap { key, value in
            guard key.hasPrefix(flutterPreferencesPrefix + playbackPrefix),
                  let articleID = Int64(key.dropFirst((flutterPreferencesPrefix + playbackPrefix).count)),
                  articleID > 0,
                  let positionMs = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return LegacyPlaybackProgressImport(articleID: articleID, positionMs: positionMs)
        }
        .sorted { $0.articleID < $1.articleID }
    }

    static func mergePlaybackProgressImports(
        sharedPreferences: [LegacyPlaybackProgressImport],
        keychain: [LegacyPlaybackProgressImport]
    ) -> [LegacyPlaybackProgressImport] {
        var byArticleID = [Int64: LegacyPlaybackProgressImport]()
        for progress in keychain {
            byArticleID[progress.articleID] = progress
        }
        for progress in sharedPreferences {
            byArticleID[progress.articleID] = progress
        }
        return byArticleID.values.sorted { $0.articleID < $1.articleID }
    }

    static func parseDownloadImports(
        _ values: [String: String],
        audioCache: URL,
        fileManager: FileManager = .default
    ) -> [LegacyDownloadImport] {
        let root = audioCache.standardizedFileURL.path + "/"
        return values.compactMap { key, value in
            guard key.hasPrefix(downloadPathPrefix),
                  !key.hasPrefix(downloadPathByURLPrefix),
                  let enclosureID = Int64(key.dropFirst(downloadPathPrefix.count)), enclosureID > 0 else {
                return nil
            }
            let source = URL(fileURLWithPath: value).standardizedFileURL
            guard source.path.hasPrefix(root),
                  source.deletingPathExtension().lastPathComponent.hasPrefix(audioFilePrefix),
                  (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  fileManager.isReadableFile(atPath: source.path) else { return nil }
            return LegacyDownloadImport(enclosureID: enclosureID, sourceFile: source)
        }
        .sorted { $0.enclosureID < $1.enclosureID }
    }

    static func parseFeedOpenInMinifluxImports(
        _ rawValue: String?
    ) -> [LegacyFeedOpenInMinifluxImport] {
        guard let rawValue,
              let data = rawValue.data(using: .utf8),
              let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return overrides.compactMap { feedIDValue, overrideValue in
            guard let feedID = Int64(feedIDValue),
                  feedID > 0,
                  let override = overrideValue as? [String: Any],
                  let value = override["openMinifluxEntry"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.stringValue == "1" else {
                return nil
            }
            return LegacyFeedOpenInMinifluxImport(feedID: feedID, openInMiniflux: true)
        }
        .sorted { $0.feedID < $1.feedID }
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

    // Only settings with a retained native/Core semantic belong here. Explicitly
    // retired Flutter preferences such as useBlackMode and the replaced mobile
    // syncOnStart preference must not be counted as D9 migration candidates.
    // Includes recognized legacy values retained for the upgrade diagnostic.
    // `autoDownloadAudioAfterSync` is not a compatible Core media policy.
    private static let auditedSettings: Set<String> = [
        "brightnessMode", "activateTruncate", "charactersToTruncate",
        "autoDownloadAudioAfterSync", "downloadAudioOnlyOnWifi",
        "deleteAudioAfterPlayback", "audioDownloadRetentionDays"
    ]

    private static let compatibleMediaSettings: Set<String> = [
        "downloadAudioOnlyOnWifi",
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

    private static func playbackArticleID(_ key: String) -> Int64? {
        guard key.hasPrefix(playbackPrefix),
              let articleID = Int64(key.dropFirst(playbackPrefix.count)), articleID > 0 else {
            return nil
        }
        return articleID
    }

    private static func stringValues(_ values: [String: Any]) -> [String: String] {
        values.reduce(into: [:]) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }

    private static func keychainValues() -> [String: String]? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: flutterKeychainService,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return nil
        }
        let items = (result as? [[CFString: Any]]) ?? []

        return items.reduce(into: [:]) { values, item in
            guard let account = item[kSecAttrAccount] as? String,
                  let data = item[kSecValueData] as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return
            }
            values[account] = value
        }
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
