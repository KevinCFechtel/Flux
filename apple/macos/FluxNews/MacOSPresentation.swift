import Foundation
import UserNotifications

enum StatusItemPresentation {
    static func title(unreadTotal: UInt64, hasPendingNewData: Bool) -> String { let unread = unreadTotal == 0 ? "" : unreadTotal > 999 ? "999+" : "\(unreadTotal)"; return switch (hasPendingNewData, unread.isEmpty) { case (false, _): unread; case (true, true): "•"; case (true, false): "• \(unread)" } }
    static func accessibilityValue(unreadTotal: UInt64, hasPendingNewData: Bool) -> String { let unread = unreadTotal == 1 ? String(localized: "1 unread article") : String(format: String(localized: "%lld unread articles"), unreadTotal); return hasPendingNewData ? String(format: String(localized: "%@, new data available"), unread) : unread }
}

struct FeedIconRequestState { private var inFlight = Set<String>(); mutating func begin(_ key: String, cached: Bool) -> Bool { !cached && inFlight.insert(key).inserted }; mutating func complete(_ key: String) { inFlight.remove(key) }; func isInFlight(_ key: String) -> Bool { inFlight.contains(key) } }
struct ArticleThumbnailRequestState { private var inFlight = Set<String>(); mutating func begin(_ key: String, cached: Bool) -> Bool { !cached && inFlight.insert(key).inserted }; mutating func complete(_ key: String) { inFlight.remove(key) }; func isInFlight(_ key: String) -> Bool { inFlight.contains(key) } }
