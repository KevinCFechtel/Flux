import Foundation

enum IOSAccountValidationFailure {
    case invalidURL, network, unauthorized, incompatibleServer, invalidResponse, invalidCustomHeader
}

enum IOSAccountValidationPresentation {
    static func message(for failure: IOSAccountValidationFailure) -> String {
        switch failure {
        case .invalidURL: "Enter a valid HTTP or HTTPS Miniflux server URL."
        case .network: "The Miniflux server could not be reached. Check the server URL and network connection."
        case .unauthorized: "Miniflux rejected the API key."
        case .incompatibleServer: "This server does not provide the required Miniflux endpoint."
        case .invalidResponse: "The Miniflux server returned an unexpected response."
        case .invalidCustomHeader: "Custom headers must have unique valid names and cannot replace FluxNews transport headers."
        }
    }

    static func failure(for error: Error) -> IOSAccountValidationFailure {
        switch error {
        case AccountValidationError.InvalidUrl, AccountValidationError.UnsupportedUrlScheme: .invalidURL
        case AccountValidationError.Network, AccountValidationError.ServerUnavailable: .network
        case AccountValidationError.Unauthorized: .unauthorized
        case AccountValidationError.IncompatibleServer: .incompatibleServer
        case AccountValidationError.InvalidCustomHeader: .invalidCustomHeader
        case AccountValidationError.InvalidResponse: .invalidResponse
        default: .invalidResponse
        }
    }
}
