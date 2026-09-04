import Foundation
import Security

struct IOSCustomHTTPHeader: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

struct IOSMinifluxCredentials: Codable, Equatable, CustomStringConvertible {
    var server: String
    var apiKey: String
    var customHeaders: [IOSCustomHTTPHeader]

    var description: String { "IOSMinifluxCredentials(server: \(server), apiKey: <redacted>, headers: \(customHeaders.count))" }
}

protocol IOSCredentialStoreProtocol {
    func load() throws -> IOSMinifluxCredentials?
    func save(_ credentials: IOSMinifluxCredentials) throws
    func remove() throws
}

struct IOSKeychainCredentialStore: IOSCredentialStoreProtocol {
    private static let account = "credentials"

    // This service is intentionally unrelated to Flutter's secure-storage service.
    private var service: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.kevincfechtel.fluxNews.nativeDev"
        return "\(bundleID).native-miniflux"
    }

    func load() throws -> IOSMinifluxCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
        return try JSONDecoder().decode(IOSMinifluxCredentials.self, from: data)
    }

    func save(_ credentials: IOSMinifluxCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.error(status) }
        var insertion = query
        insertion[kSecValueData] = data
        insertion[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard insertionStatus == errSecSuccess else { throw Self.error(insertionStatus) }
    }

    func remove() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error"
        ])
    }
}

final class IOSMemoryCredentialStore: IOSCredentialStoreProtocol {
    var credentials: IOSMinifluxCredentials?

    func load() throws -> IOSMinifluxCredentials? { credentials }
    func save(_ credentials: IOSMinifluxCredentials) throws { self.credentials = credentials }
    func remove() throws { self.credentials = nil }
}
