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
