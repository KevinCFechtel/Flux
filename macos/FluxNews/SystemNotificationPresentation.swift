import Foundation

enum SystemNotificationPresentation {
    static func body(newCount: UInt32, submittedAt: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let count = newCount == 1 ? "1 new article" : "\(newCount) new articles"
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "\(count) · \(formatter.string(from: submittedAt))"
    }
}
