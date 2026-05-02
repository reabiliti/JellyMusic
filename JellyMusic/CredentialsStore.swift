import Foundation
import Security

final class CredentialsStore {
    private let service = "JellyMusic.Credentials"
    private let account = "current"
    private let profilesAccount = "profiles"

    func load() -> JellyfinCredentials? {
        if let activeProfile = loadProfiles().first {
            return activeProfile.credentials
        }

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(JellyfinCredentials.self, from: data)
    }

    func save(_ credentials: JellyfinCredentials) {
        clear()
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadProfiles() -> [ServerProfile] {
        var query = baseQuery(account: profilesAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return []
        }

        return (try? JSONDecoder().decode([ServerProfile].self, from: data)) ?? []
    }

    func saveProfiles(_ profiles: [ServerProfile]) {
        SecItemDelete(baseQuery(account: profilesAccount) as CFDictionary)
        guard let data = try? JSONEncoder().encode(profiles) else { return }

        var query = baseQuery(account: profilesAccount)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account ?? self.account
        ]
    }
}
