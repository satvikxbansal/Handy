import Foundation
import Security

enum KeychainManager {
    private static let service = "com.handydotapp.handy"

    enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        case readFailed
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Keychain save failed (status: \(status))"
            case .readFailed: return "Could not read from keychain"
            case .deleteFailed(let status): return "Keychain delete failed (status: \(status))"
            }
        }
    }

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Convenience for API keys

    enum APIKeyType: String {
        case claude = "handy_claude_api_key"
        case openAI = "handy_openai_api_key"
        case assemblyAI = "handy_assemblyai_api_key"
        case sarvam = "handy_sarvam_api_key"
        case braveSearch = "handy_brave_search_api_key"
        case jinaReader = "handy_jina_reader_api_key"
        case github = "handy_github_api_key"
    }

    static func saveAPIKey(_ type: APIKeyType, value: String) throws {
        try save(key: type.rawValue, value: value)
    }

    static func getAPIKey(_ type: APIKeyType) -> String? {
        read(key: type.rawValue)
    }

    static func deleteAPIKey(_ type: APIKeyType) throws {
        try delete(key: type.rawValue)
    }

    static func maskedKey(_ type: APIKeyType) -> String {
        guard let key = getAPIKey(type), key.count > 8 else { return "" }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)••••••••\(suffix)"
    }

    static func hasAPIKey(_ type: APIKeyType) -> Bool {
        getAPIKey(type) != nil
    }

    /// One-time copy from the former ElevenLabs key slot so users are not prompted to re-enter after the Sarvam swap.
    private static let legacyElevenLabsAccount = "handy_elevenlabs_api_key"

    static func migrateLegacyElevenLabsKeyToSarvamIfNeeded() {
        guard getAPIKey(.sarvam) == nil else { return }
        guard let legacy = read(key: legacyElevenLabsAccount), !legacy.isEmpty else { return }
        try? saveAPIKey(.sarvam, value: legacy)
    }
}
