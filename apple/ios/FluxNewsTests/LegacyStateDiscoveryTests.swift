import XCTest
@testable import FluxNews

final class LegacyStateDiscoveryTests: XCTestCase {
    func testDiskDownloadDiscoveryWithoutLegacyKeysAndStalePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("audio_42_1791633000000.mp3")
        let second = root.appendingPathComponent("audio_42_1791634000000.mp3")
        let other = root.appendingPathComponent("audio_43_1791635000000.m4a")
        for file in [first, second, other] {
            try Data("audio".utf8).write(to: file)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: second.path)
        let values = ["audio_download_path_42": "/old/sandbox/audio_42_1791633000000.mp3"]
        let items = LegacyStateDiscovery.mergeDownloadImports(
            values, audioCache: root, articleIDs: [42: 1000]
        )
        XCTAssertEqual(items.map(\.enclosureID), [42, 43])
        XCTAssertEqual(items[0].sourceFile, second)
        XCTAssertEqual(items[0].articleID, 1000)
        XCTAssertNil(items[1].articleID)
    }

    func testDiskDownloadDiscoveryRejectsUnsafeOrInvalidNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["audio_-42_1791633000000.mp3", "audio_0_1791633000000.mp3",
                     "audio_42_bad.mp3", "audio_42_1791633000000.mp3.extra",
                     "artwork_42_1791633000000.jpg"] {
            try Data("audio".utf8).write(to: root.appendingPathComponent(name))
        }
        XCTAssertTrue(LegacyStateDiscovery.discoverDownloadFiles(audioCache: root).isEmpty)
    }

    func testSummaryRedactsCredentialValues() {
        let result = LegacyDiscoveryResult(
            productionIdentity: .accessible, appGroup: .accessible, keychain: .accessible,
            accountURLPresent: true, accountAPIKeyPresent: true, customHeaderCount: 2,
            compatibleSettingCount: 3, feedPreferencePresent: true, playbackProgressCount: 4,
            downloadMetadataCount: 5, downloadFileCount: 6, legacyDatabase: true, legacyCache: true
        )

        let summary = LegacyStateDiscovery.redactedSummary(result)
        XCTAssertEqual(summary["Base URL"], "present")
        XCTAssertEqual(summary["API key"], "present")
        XCTAssertFalse(summary.values.contains("secret"))
        XCTAssertFalse(summary.values.contains("https://private.example"))
    }

    func testMissingAccountIsDistinctFromAccessibleKeychain() {
        let result = LegacyDiscoveryResult(
            productionIdentity: .accessible, appGroup: .accessible, keychain: .accessible,
            accountURLPresent: false, accountAPIKeyPresent: false, customHeaderCount: 0,
            compatibleSettingCount: 0, feedPreferencePresent: false, playbackProgressCount: 0,
            downloadMetadataCount: 0, downloadFileCount: 0, legacyDatabase: false, legacyCache: false
        )

        let summary = LegacyStateDiscovery.redactedSummary(result)
        XCTAssertEqual(summary["Keychain credentials"], "accessible")
        XCTAssertEqual(summary["API key"], "absent")
    }

    func testAccountImportRequiresCompleteAccountAndPairsHeadersByLegacyID() {
        let account = LegacyStateDiscovery.parseAccountImport([
            "minifluxURL": " https://miniflux.example/ ",
            "minifluxAPIKey": " secret-key ",
            "customHeadersKey_1": " X-First ",
            "customHeadersValue_1": "one",
            "customHeadersKey_2": "X-Second",
            "customHeadersValue_2": "two",
            "customHeadersKey_incomplete": "X-Ignored"
        ])

        XCTAssertEqual(account?.serverURL, "https://miniflux.example/")
        XCTAssertEqual(account?.apiKey, "secret-key")
        XCTAssertEqual(account?.customHeaders, [
            .init(name: "X-First", value: "one"),
            .init(name: "X-Second", value: "two")
        ])
    }

    func testAccountImportRejectsMissingCredentials() {
        XCTAssertNil(LegacyStateDiscovery.parseAccountImport([
            "minifluxURL": "https://miniflux.example/"
        ]))
        XCTAssertNil(LegacyStateDiscovery.parseAccountImport([
            "minifluxAPIKey": "secret-key"
        ]))
    }

    func testFlutterSharedPreferencesPlaybackParsingAndKeychainFallbackMerge() {
        let shared = LegacyStateDiscovery.parseFlutterSharedPreferencesPlaybackImports([
            "flutter.audio_progress_10": "5000",
            "flutter.audio_progress_20": "0",
            "flutter.audio_progress_bad": "100",
            "flutter.audio_progress_-1": "100",
            "flutter.audio_progress_30": "invalid"
        ])
        let keychain = LegacyStateDiscovery.parsePlaybackProgressImports([
            "audio_progress_10": "3000",
            "audio_progress_30": "7000",
            "audio_progress_40": "invalid",
            "other": "9000"
        ])

        XCTAssertEqual(shared, [
            .init(articleID: 10, positionMs: 5000),
            .init(articleID: 20, positionMs: 0)
        ])
        XCTAssertEqual(keychain, [
            .init(articleID: 10, positionMs: 3000),
            .init(articleID: 30, positionMs: 7000)
        ])
        XCTAssertEqual(
            LegacyStateDiscovery.mergePlaybackProgressImports(
                sharedPreferences: shared,
                keychain: keychain
            ),
            [
                .init(articleID: 10, positionMs: 5000),
                .init(articleID: 20, positionMs: 0),
                .init(articleID: 30, positionMs: 7000)
            ]
        )
    }

    func testFeedOpenInMinifluxParserRetainsOnlyPositiveValidOverridesInOrder() {
        let parsed = LegacyStateDiscovery.parseFeedOpenInMinifluxImports("""
        {
          "20": {"openMinifluxEntry": 1, "manualTruncate": 0},
          "10": {"openMinifluxEntry": 0},
          "30": {"manualTruncate": 1},
          "40": {"openMinifluxEntry": "1"},
          "0": {"openMinifluxEntry": 1},
          "-2": {"openMinifluxEntry": 1},
          "50": {"openMinifluxEntry": 1, "preferParagraph": 1}
        }
        """)

        XCTAssertEqual(parsed, [
            .init(feedID: 20, openInMiniflux: true),
            .init(feedID: 50, openInMiniflux: true)
        ])
    }

    func testFeedOpenInMinifluxParserRejectsMalformedAndUnexpectedValues() {
        XCTAssertEqual(LegacyStateDiscovery.parseFeedOpenInMinifluxImports(nil), [])
        XCTAssertEqual(LegacyStateDiscovery.parseFeedOpenInMinifluxImports("not json"), [])
        XCTAssertEqual(LegacyStateDiscovery.parseFeedOpenInMinifluxImports("[]"), [])
        XCTAssertEqual(
            LegacyStateDiscovery.parseFeedOpenInMinifluxImports("{\"1\": {\"openMinifluxEntry\": true}}"),
            []
        )
    }

    func testGlobalPreferencesParserAcceptsOnlyExactFlutterBooleanStrings() {
        XCTAssertEqual(
            LegacyStateDiscovery.parseGlobalPreferencesImport([
                "markAsReadOnScrollOver": "true",
                "removeNewsFromListWhenRead": "false"
            ]),
            .init(markReadOnScrollover: true, removeArticlesWhenMarkedRead: false)
        )
        XCTAssertEqual(
            LegacyStateDiscovery.parseGlobalPreferencesImport([
                "markAsReadOnScrollOver": "TRUE",
                "removeNewsFromListWhenRead": " false "
            ]),
            .init(markReadOnScrollover: nil, removeArticlesWhenMarkedRead: nil)
        )
    }

    func testSettingsFollowupParserMapsOnlyExactCompatibleValues() {
        let parsed = LegacyStateDiscovery.parseSettingsImport([
            "multilineAppBarText": "true",
            "showOnlyFeedCategoriesWithNewNews": "false",
            "tabAction": "expand",
            "rightSwipeAction": "bookmark",
            "secondRightSwipeAction": "none",
            "leftSwipeAction": "open",
            "secondLeftSwipeAction": "openComments",
            "startupCategorie": "3",
            "startupFeedSelection": "42",
            "backgroundSyncIntervalMinutes": "30",
            "autoDownloadAudioAfterSync": "false",
            "syncReadStatusImmediately": "true"
        ])

        XCTAssertEqual(parsed.showArticleCount, true)
        XCTAssertEqual(parsed.hideEmptyNavigationEntries, false)
        XCTAssertTrue(parsed.tabActionExpands)
        XCTAssertEqual(parsed.leadingFull!, .starUnstar)
        XCTAssertNil(parsed.leadingAdditional!)
        XCTAssertEqual(parsed.trailingFull!, .openOriginal)
        XCTAssertEqual(parsed.trailingAdditional!, .comments)
        XCTAssertEqual(parsed.startupMode, 3)
        XCTAssertEqual(parsed.startupFeedID, 42)
        XCTAssertEqual(parsed.backgroundSyncEnabled, true)
        XCTAssertEqual(parsed.autoDownloadListeningList, false)
    }

    func testSettingsFollowupParserRejectsMalformedBooleansAndNumbers() {
        let parsed = LegacyStateDiscovery.parseSettingsImport([
            "multilineAppBarText": " TRUE ",
            "showOnlyFeedCategoriesWithNewNews": "1",
            "tabAction": "open",
            "rightSwipeAction": "unknown",
            "startupCategorie": " 2",
            "backgroundSyncIntervalMinutes": "-1",
            "autoDownloadAudioAfterSync": "False"
        ])

        XCTAssertNil(parsed.showArticleCount)
        XCTAssertNil(parsed.hideEmptyNavigationEntries)
        XCTAssertFalse(parsed.tabActionExpands)
        XCTAssertNil(parsed.leadingFull)
        XCTAssertNil(parsed.startupMode)
        XCTAssertNil(parsed.backgroundSyncEnabled)
        XCTAssertNil(parsed.autoDownloadListeningList)
    }
}
