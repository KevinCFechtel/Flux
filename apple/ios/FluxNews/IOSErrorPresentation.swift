import Foundation

enum IOSErrorContext {
    case startup
    case contentLoad
    case sync
    case search
    case reader
    case articleAction
    case feedDiscovery
    case feedCreation
    case categoryCreation
    case feedSettingsLoad
    case feedSettingsSave
}

enum IOSCoreError: Error {
    case notConfigured
}

enum IOSErrorPresentation {
    static func message(for error: Error, context: IOSErrorContext) -> String {
        if case .startup = context, let validation = error as? AccountValidationError {
            return IOSAccountValidationPresentation.message(for: IOSAccountValidationPresentation.failure(for: validation))
        }

        return switch context {
        case .startup: "FluxNews could not start. Check the account configuration and try again."
        case .contentLoad: "Articles could not be loaded. Please try again."
        case .sync: "News could not be synced. Please try again."
        case .search: "Search could not be completed. Please try again."
        case .reader: "The article could not be loaded in Reader."
        case .articleAction: "The article could not be updated. Please try again."
        case .feedDiscovery: "Could not discover feeds. Please try again."
        case .feedCreation: "Could not add feed. Please try again."
        case .categoryCreation: "Could not add category. Please try again."
        case .feedSettingsLoad: "Feed settings could not be loaded. Please try again."
        case .feedSettingsSave: "Feed settings could not be saved. Please try again."
        }
    }
}
