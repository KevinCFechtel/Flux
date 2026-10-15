import XCTest

final class AccountPresentationTests: XCTestCase {
    func testValidationErrorsUseDistinctUsefulMessages() {
        XCTAssertEqual(
            AccountValidationPresentation.message(for: .invalidURL),
            "Enter a valid HTTP or HTTPS Miniflux server URL."
        )
        XCTAssertEqual(
            AccountValidationPresentation.message(for: .unauthorized),
            "Miniflux rejected the API key."
        )
        XCTAssertNotEqual(
            AccountValidationPresentation.message(for: .network),
            AccountValidationPresentation.message(for: .unauthorized)
        )
    }

    func testCustomHeaderValidationExplainsTheTransportPolicy() {
        XCTAssertEqual(
            AccountValidationPresentation.message(for: .invalidCustomHeader),
            "Custom headers must have unique valid names and cannot replace FluxNews transport headers."
        )
    }

    func testSupportRedactionRemovesSensitiveFieldsAndPaths() {
        let input = "Authorization: Bearer abc123 https://server.test/path?token=123 /Users/me/Media/file.mp3 secret-value"
        let safe = SupportLogRedaction.sanitize(input, secrets: ["secret-value"])
        for value in ["abc123", "server.test", "/Users/me", "secret-value"] {
            XCTAssertFalse(safe.contains(value))
        }
        XCTAssertEqual(SupportLogRedaction.sanitize("sync completed items=3"), "sync completed items=3")
    }

    func testMacSupportDiagnosticsPersistenceBoundsAndClear() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = MacSupportDiagnostics(root: root, defaults: defaults, capacity: 3, maximumBytes: 4_096)
        XCTAssertNil(logs.record(.debug, "sync", "hidden"))
        logs.record(.info, "sync", "first")
        logs.setDebug(true)
        logs.record(.debug, "sync", "visible")
        for index in 0..<12 {
            logs.record(.warning, "media", "transfer \(index)")
        }
        XCTAssertLessThanOrEqual(logs.snapshot().count, 3)
        let reopened = MacSupportDiagnostics(root: root, defaults: defaults, capacity: 3, maximumBytes: 4_096)
        XCTAssertTrue(reopened.debugEnabled)
        XCTAssertEqual(reopened.snapshot().count, logs.snapshot().count)
        XCTAssertTrue(reopened.exportText().contains("FluxNews macOS Diagnostics"))
        reopened.clear()
        XCTAssertTrue(reopened.snapshot().isEmpty)
        XCTAssertTrue(MacSupportDiagnostics(root: root, defaults: defaults).snapshot().isEmpty)
    }

    func testMacSupportDiagnosticsRedactsValuesBeforeWriting() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = MacSupportDiagnostics(root: root)
        logs.registerSecrets(["secret-header-value"])
        let safe = logs.record(.error, "core.http", "Authorization: abc https://news.example/path?token=123 /Users/me/media.mp3 secret-header-value")!
        XCTAssertFalse(safe.contains("secret-header-value"))
        XCTAssertFalse(safe.contains("news.example"))
        XCTAssertFalse(safe.contains("/Users/me"))
        XCTAssertFalse(logs.exportText().contains("news.example"))
        XCTAssertFalse(logs.exportText().contains("secret-header-value"))
    }

    func testUnencryptedHTTPWarningOnlyForValidHTTPServerURLs() {
        XCTAssertTrue(AccountTransportWarning.usesUnencryptedHTTP("http://news.example:8080/miniflux"))
        XCTAssertTrue(AccountTransportWarning.usesUnencryptedHTTP("  HTTP://news.example/  "))
        XCTAssertFalse(AccountTransportWarning.usesUnencryptedHTTP("https://news.example"))
        XCTAssertFalse(AccountTransportWarning.usesUnencryptedHTTP("http://"))
        XCTAssertFalse(AccountTransportWarning.usesUnencryptedHTTP("not a URL"))
        XCTAssertFalse(AccountTransportWarning.usesUnencryptedHTTP(""))
    }

    func testAboutUsesRealBundleVersionAndBuildWithSafeFallback() {
        XCTAssertEqual(MacOSAboutInformation.version(from: ["CFBundleShortVersionString": " 3.0.0 "]), "3.0.0")
        XCTAssertEqual(MacOSAboutInformation.build(from: ["CFBundleVersion": "20261015"]), "20261015")
        XCTAssertEqual(MacOSAboutInformation.version(from: [:]), String(localized: "Unknown"))
        XCTAssertEqual(MacOSAboutInformation.build(from: ["CFBundleVersion": "  "]), String(localized: "Unknown"))
        XCTAssertEqual(MacOSAboutInformation.licenseURL.absoluteString, "https://github.com/KevinCFechtel/Flux/blob/main/LICENSE")
    }

    func testMinifluxEntryURLUsesCoreResolvedRootAndSubpathURLs() {
        XCTAssertEqual(
            MinifluxEntryURL.resolve(articleID: 583862) { _ in
                "https://news.example/unread/entry/583862"
            }?.absoluteString,
            "https://news.example/unread/entry/583862"
        )
        XCTAssertEqual(
            MinifluxEntryURL.resolve(articleID: 583862) { _ in
                "https://news.example/miniflux/unread/entry/583862"
            }?.absoluteString,
            "https://news.example/miniflux/unread/entry/583862"
        )
    }

    func testInvalidCoreResolvedEntryURLHasNoSwiftFallback() {
        XCTAssertNil(MinifluxEntryURL.resolve(articleID: 583862) { _ in "not a URL" })
    }
}
