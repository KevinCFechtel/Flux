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
}
