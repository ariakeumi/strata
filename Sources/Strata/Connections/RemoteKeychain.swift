import Foundation
import StrataModel
import StrataSupport
import Security

/// Synchronous Security calls stay at this boundary. Independent credential stores can exercise errors and races
/// without accessing the login keychain, while production keeps the same native item format and access policy.
package nonisolated struct KeychainAccess: Sendable {
    package let copy: @Sendable (CFDictionary) -> (OSStatus, CFTypeRef?)
    package let add: @Sendable (CFDictionary) -> OSStatus
    package let update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
    package let delete: @Sendable (CFDictionary) -> OSStatus

    package static let system = KeychainAccess(copy: { query in
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result)
    }, add: { SecItemAdd($0, nil) }, update: { SecItemUpdate($0, $1) }, delete: { SecItemDelete($0) })
}

/// S3 secret keys, one generic password per server in the login keychain ("Strata S3", the server's ID). Never logged,
/// never in preferences.
package nonisolated struct RemoteKeychain: Sendable {
    package static let shared = RemoteKeychain(access: .system)
    private let access: KeychainAccess

    package init(access: KeychainAccess) { self.access = access }

    package var smb: KeychainSecrets { KeychainSecrets(access: access, service: "Strata SMB") }
    private var s3: KeychainSecrets { KeychainSecrets(access: access, service: "Strata S3") }

    package func setSecret(_ secret: String, for server: RemoteServer) -> Bool {
        s3.set(secret, account: server.id, label: "Strata S3: \(server.bucket ?? server.host)")
    }

    package func secret(for server: RemoteServer) -> String? { s3.secret(account: server.id) }

    @discardableResult
    package func delete(_ server: RemoteServer) -> Bool { s3.delete(account: server.id) }
}

package nonisolated struct KeychainSecrets: Sendable {
    let access: KeychainAccess
    let service: String

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    package func set(_ secret: String, account: String, label: String) -> Bool {
        let base = query(account: account)
        let changes: [String: Any] = [kSecValueData as String: Data(secret.utf8), kSecAttrLabel as String: label]
        // Updating retains the item's native access policy and leaves its old value intact on failure.
        let updated = access.update(base as CFDictionary, changes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = base
        item.merge(changes) { _, replacement in replacement }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = access.add(item as CFDictionary)
        guard added == errSecDuplicateItem else { return added == errSecSuccess }
        // Another writer created this exact item after our lookup. Retry the update once, without deleting it.
        return access.update(base as CFDictionary, changes as CFDictionary) == errSecSuccess
    }

    package func secret(account: String, interactive: Bool = true) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip }
        let (status, result) = access.copy(query as CFDictionary)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    package func delete(account: String) -> Bool {
        let status = access.delete(query(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
