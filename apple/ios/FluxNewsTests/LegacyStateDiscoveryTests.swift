import XCTest
@testable import FluxNews

final class LegacyStateDiscoveryTests: XCTestCase {
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
}
