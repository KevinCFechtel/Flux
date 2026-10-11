import OSLog

final class CoreDiagnosticLogger: DiagnosticListener, @unchecked Sendable {
    func onDiagnostic(record: DiagnosticRecord) {
        let logger = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "core.\(record.target)")
        switch record.level {
        case .trace, .debug:
            logger.debug("\(record.message, privacy: .public)")
        case .info:
            logger.notice("\(record.message, privacy: .public)")
        case .warn:
            logger.warning("\(record.message, privacy: .public)")
        case .error:
            logger.error("\(record.message, privacy: .public)")
        }
    }
}

enum NativeLog {
    static let app = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "app")
    static let sync = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "sync")
    static let keychain = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "keychain")
    static let launchAtLogin = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "launch_at_login")
    static let shortcut = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "shortcut")
    static let feedIcon = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "feed_icon")
    static let scrollover = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "scrollover")
    static let snapshot = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "snapshot")
    static let notification = Logger(subsystem: "dev.kevincfechtel.fluxNews", category: "notification")
}
