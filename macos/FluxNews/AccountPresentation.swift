import Foundation

enum AccountValidationFailure {
    case invalidURL
    case network
    case unauthorized
    case incompatibleServer
    case invalidResponse
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
        }
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
