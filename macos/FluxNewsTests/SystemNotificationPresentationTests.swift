import Foundation
import XCTest

final class SystemNotificationPresentationTests: XCTestCase {
    func testBodyIncludesPluralCountAndLocalizedDateTime() {
        let body = SystemNotificationPresentation.body(
            newCount: 3,
            submittedAt: Date(timeIntervalSince1970: 1_777_242_840),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertTrue(body.hasPrefix("3 new articles · "))
        XCTAssertFalse(body.split(separator: "·").last!.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testBodyPreservesSingularCount() {
        let body = SystemNotificationPresentation.body(
            newCount: 1,
            submittedAt: Date(timeIntervalSince1970: 1_777_242_840),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertTrue(body.hasPrefix("1 new article · "))
    }
}
