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
