import Foundation
import Security

enum Keychain {
    static let service = "FabianKirschenmann.LongevityCompass"

    enum Key: String {
        case openRouterAPIKey = "openrouter.apiKey"
        case openRouterModel  = "openrouter.model"
    }

    static func set(_ value: String, for key: Key) {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        guard let data = result as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func delete(_ key: Key) {
        let query = baseQuery(key)
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
