import AppKit
import XCTest

final class KeyboardCommandRoutingTests: XCTestCase {
    func testSpaceOpensReaderDetail() {
        XCTAssertEqual(ArticleKeyboardRouting.command(keyCode: 49, charactersIgnoringModifiers: " ", modifierFlags: []), .openDetail)
    }

    func testModifiedSpaceIsNotHandled() {
        XCTAssertNil(ArticleKeyboardRouting.command(keyCode: 49, charactersIgnoringModifiers: " ", modifierFlags: .command))
    }
}
