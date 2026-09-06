import XCTest
@testable import FluxNews

final class IOSErrorPresentationTests: XCTestCase {
    private let technicalError = NSError(domain: "FluxNewsTests", code: 42, userInfo: [NSLocalizedDescriptionKey: "database password and server details"])

    func testUnknownErrorsNeverExposeTheirTechnicalDescription() {
        let message = IOSErrorPresentation.message(for: technicalError, context: .contentLoad)

        XCTAssertEqual(message, "Articles could not be loaded. Please try again.")
        XCTAssertFalse(message.contains("database password"))
    }

    func testContextsUseStableUserFacingMessages() {
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .startup), "FluxNews could not start. Check the account configuration and try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .contentLoad), "Articles could not be loaded. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .sync), "News could not be synced. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .search), "Search could not be completed. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .reader), "The article could not be loaded in Reader.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .articleAction), "The article could not be updated. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedDiscovery), "Could not discover feeds. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedCreation), "Could not add feed. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .categoryCreation), "Could not add category. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedSettingsLoad), "Feed settings could not be loaded. Please try again.")
        XCTAssertEqual(IOSErrorPresentation.message(for: technicalError, context: .feedSettingsSave), "Feed settings could not be saved. Please try again.")
    }

    func testAccountValidationKeepsTypedPresentationMapping() {
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.InvalidUrl, context: .startup), "Enter a valid HTTP or HTTPS Miniflux server URL.")
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.UnsupportedUrlScheme, context: .startup), "Enter a valid HTTP or HTTPS Miniflux server URL.")
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.Network, context: .startup), "The Miniflux server could not be reached. Check the server URL and network connection.")
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.ServerUnavailable, context: .startup), "The Miniflux server could not be reached. Check the server URL and network connection.")
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.Unauthorized, context: .startup), "Miniflux rejected the API key.")
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.IncompatibleServer, context: .startup), "This server does not provide the required Miniflux endpoint.")
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.InvalidCustomHeader, context: .startup), "Custom headers must have unique valid names and cannot replace FluxNews transport headers.")
        XCTAssertEqual(IOSErrorPresentation.message(for: AccountValidationError.InvalidResponse, context: .startup), "The Miniflux server returned an unexpected response.")
    }
}
