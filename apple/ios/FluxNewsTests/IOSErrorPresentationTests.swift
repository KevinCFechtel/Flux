import XCTest
@testable import FluxNews

final class IOSErrorPresentationTests: XCTestCase {
    private let technicalError = NSError(domain: "FluxNewsTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "database password and server details"])

    func testUnknownErrorsNeverExposeTheirTechnicalDescription() {
        let message = IOSErrorPresentation.message(for: technicalError, context: .contentLoad)

        XCTAssertEqual(message, String(localized: "Articles could not be loaded. Please try again."))
        XCTAssertFalse(message.contains("database password"))
    }

    func testContextsUseStableUserFacingMessages() {
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .startup), String(localized: "FluxNews could not start. Check the account configuration and try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .contentLoad), String(localized: "Articles could not be loaded. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .sync), String(localized: "News could not be synced. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .search), String(localized: "Search could not be completed. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .reader), String(localized: "The article could not be loaded in Reader."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .articleAction), String(localized: "The article could not be updated. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedDiscovery), String(localized: "Could not discover feeds. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedCreation), String(localized: "Could not add feed. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .categoryCreation), String(localized: "Could not add category. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedSettingsLoad), String(localized: "Feed settings could not be loaded. Please try again."))
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedSettingsSave), String(localized: "Feed settings could not be saved. Please try again."))
    }

    func testAccountValidationKeepsTypedPresentationMapping() {
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.InvalidUrl, context: .startup), String(localized: "Enter a valid HTTP or HTTPS Miniflux server URL."))
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.UnsupportedUrlScheme, context: .startup), String(localized: "Enter a valid HTTP or HTTPS Miniflux server URL."))
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.Network, context: .startup), String(localized: "The Miniflux server could not be reached. Check the server URL and network connection."))
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.ServerUnavailable, context: .startup), String(localized: "The Miniflux server could not be reached. Check the server URL and network connection."))
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.Unauthorized, context: .startup), String(localized: "Miniflux rejected the API key."))
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.IncompatibleServer, context: .startup), String(localized: "This server does not provide the required Miniflux endpoint."))
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.InvalidCustomHeader, context: .startup), String(localized: "Custom headers must have unique valid names and cannot replace FluxNews transport headers."))
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.InvalidResponse, context: .startup), String(localized: "The Miniflux server returned an unexpected response."))
    }
}


final class IOSAppDiagnosticsTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FluxNewsDiagnosticsTests")
            .appendingPathComponent(UUID().uuidString)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "FluxNewsDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDiagnosticsAreBoundedAndDebugIsOptIn() {
        let diagnostics = IOSAppDiagnostics(
            defaults: makeDefaults(),
            rootDirectory: makeRoot(),
            maxEntries: 3
        )

        XCTAssertNil(
            diagnostics.record(
                level: .debug,
                category: "test",
                message: "hidden"
            )
        )

        for index in 0..<5 {
            diagnostics.record(
                level: .info,
                category: "test",
                message: "entry-\(index)"
            )
        }

        XCTAssertEqual(
            diagnostics.snapshot().map(\.message),
            ["entry-2", "entry-3", "entry-4"]
        )
    }

    func testDebugPreferenceAndEntriesSurviveRelaunch() {
        let root = makeRoot()
        let defaults = makeDefaults()
        let first = IOSAppDiagnostics(
            defaults: defaults,
            rootDirectory: root
        )
        first.setDebugLoggingEnabled(true)
        first.record(
            level: .debug,
            category: "test",
            message: "debug-entry"
        )

        let relaunched = IOSAppDiagnostics(
            defaults: defaults,
            rootDirectory: root
        )

        XCTAssertTrue(relaunched.isDebugLoggingEnabled)
        XCTAssertTrue(
            relaunched.snapshot().contains {
                $0.message == "debug-entry"
            }
        )
    }

    func testSensitiveValuesAndCredentialPatternsAreRedactedBeforePersistence() {
        let diagnostics = IOSAppDiagnostics(
            defaults: makeDefaults(),
            rootDirectory: makeRoot()
        )
        diagnostics.setSensitiveValues([
            "super-secret-api-key",
            "custom-header-secret"
        ])

        diagnostics.record(
            level: .error,
            category: "test",
            message: "apiKey=other-secret key=super-secret-api-key header=custom-header-secret"
        )

        let message = diagnostics.snapshot().last?.message ?? ""
        XCTAssertFalse(message.contains("super-secret-api-key"))
        XCTAssertFalse(message.contains("custom-header-secret"))
        XCTAssertFalse(message.contains("other-secret"))
        XCTAssertTrue(message.contains("<redacted>"))
    }

    func testExportContainsSupportMetadataAndRecords() throws {
        let diagnostics = IOSAppDiagnostics(
            defaults: makeDefaults(),
            rootDirectory: makeRoot()
        )
        diagnostics.record(
            level: .warning,
            category: "media-playback",
            message: "device playback warning"
        )

        let url = try diagnostics.makeExportURL()
        let export = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(export.contains("FluxNews Diagnostics"))
        XCTAssertTrue(export.contains("App version:"))
        XCTAssertTrue(export.contains("OS:"))
        XCTAssertTrue(export.contains("[WARNING] [media-playback] device playback warning"))
    }
}
