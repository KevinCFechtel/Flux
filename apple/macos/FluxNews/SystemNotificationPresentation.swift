import Foundation

enum SystemNotificationPresentation {
    static func body(newCount: UInt32, submittedAt: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let count = newCount == 1
            ? String(localized: "1 new article", locale: locale)
            : String(format: String(localized: "%lld new articles", locale: locale), locale: locale, newCount)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return String(format: String(localized: "%@ · %@", locale: locale), locale: locale, count, formatter.string(from: submittedAt))
    }
}
