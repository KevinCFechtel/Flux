import Foundation

enum AccountValidationFailure {
    case invalidURL
    case network
    case unauthorized
    case incompatibleServer
    case invalidResponse
    case invalidCustomHeader
}

enum AccountValidationPresentation {
    static func message(for failure: AccountValidationFailure) -> String {
        switch failure {
        case .invalidURL:
            "Enter a valid HTTP or HTTPS Miniflux server URL."
        case .network:
            "The Miniflux server could not be reached. Check the server URL and network connection."
        case .unauthorized:
            "Miniflux rejected the API key."
        case .incompatibleServer:
            "This server does not provide the required Miniflux endpoint."
        case .invalidResponse:
            "The Miniflux server returned an unexpected response."
        case .invalidCustomHeader:
            "Custom headers must have unique valid names and cannot replace FluxNews transport headers."
        }
    }
}

enum NativeErrorPresentation {
    static func message(for error: Error) -> String {
        switch error {
        case SystemNotificationError.authorizationDenied:
            String(localized: "FluxNews notification permission is disabled. Enable notifications in macOS System Settings to use System Notifications.")
        default:
            String(localized: "Something went wrong. Please try again.")
        }
    }
}

enum SystemNotificationError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        String(localized: "FluxNews notification permission is disabled. Enable notifications in macOS System Settings to use System Notifications.")
    }
}

enum MinifluxEntryURL {
    static func resolve(articleID: Int64, using coreURL: (Int64) -> String) -> URL? {
        guard let url = URL(string: coreURL(articleID)),
              ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil else { return nil }
        return url
    }
}
