import Darwin
import Foundation
import Security
import Synchronization

/// One login-keychain item for saved SMB passwords, indexed by the same account keys as the former per-profile items.
package nonisolated final class SMBKeychain: Sendable {
    private static let sharedAccount = "saved-passwords"

    private struct Snapshot {
        var revision: Data?
        var passwords: [String: String] = [:]
    }

    private let legacy: KeychainSecrets
    private let lockDirectory: URL?
    private let cached = Mutex<Snapshot?>(nil)
    private var item: [String: Any] { legacy.query(account: Self.sharedAccount) }

    init(legacy: KeychainSecrets, lockDirectory: URL?) {
        self.legacy = legacy
        self.lockDirectory = lockDirectory
    }

    package func secret(account: String, interactive: Bool) -> String? {
        cached.withLock { cache in
            guard let current = read(interactive: interactive, cache: &cache) else { return nil }
            if let saved = current.passwords[account] { return saved }
            guard interactive else { return legacy.secret(account: account, interactive: false) }
            return withWriteLock {
                guard let latest = read(interactive: true, cache: &cache) else { return nil }
                if let saved = latest.passwords[account] { return saved }
                guard let old = legacy.secret(account: account) else { return nil }
                if edit(latest, cache: &cache, { $0[account] = $0[account] ?? old }) {
                    legacy.delete(account: account)
                    return cache?.passwords[account] ?? old
                }
                return old
            } ?? nil
        }
    }

    package func set(_ secret: String, account: String) -> Bool {
        cached.withLock { cache in
            withWriteLock {
                guard let current = read(interactive: true, cache: &cache),
                      edit(current, cache: &cache, { $0[account] = secret }) else { return false }
                legacy.delete(account: account)
                return true
            } ?? false
        }
    }

    package func delete(account: String) -> Bool {
        cached.withLock { cache in
            withWriteLock {
                // A surviving legacy password must be removed before clearing its replacement.
                guard let current = read(interactive: true, cache: &cache),
                      legacy.delete(account: account) else { return false }
                return edit(current, cache: &cache) { $0[account] = nil }
            } ?? false
        }
    }

    /// Serialize read-modify-write across running copies of the app. Closing the descriptor also releases the lock
    /// on crash. The directory already belongs to Strata, so no lock file needs to be created or removed.
    private func withWriteLock<Value>(_ work: () -> Value) -> Value? {
        guard let lockDirectory else { return work() }
        let fd = open(lockDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { return nil }
        }
        return work()
    }

    private func read(interactive: Bool, cache: inout Snapshot?) -> Snapshot? {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip }
        // Check the revision without reading the secret. A one-time grant can then serve every profile in this
        // process, and a change by another process invalidates the cached passwords.
        let (status, attributes) = legacy.access.copy(query as CFDictionary)
        if status == errSecSuccess,
           let revision = (attributes as? [String: Any])?[kSecAttrGeneric as String] as? Data,
           let cache, cache.revision == revision { return cache }
        cache = nil
        if status == errSecItemNotFound { return Snapshot() }
        guard status == errSecSuccess else { return nil }

        query[kSecReturnData as String] = true
        let (readStatus, result) = legacy.access.copy(query as CFDictionary)
        guard readStatus == errSecSuccess, let values = result as? [String: Any],
              let revision = values[kSecAttrGeneric as String] as? Data,
              let data = values[kSecValueData as String] as? Data,
              let passwords = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        let fresh = Snapshot(revision: revision, passwords: passwords)
        cache = fresh
        return fresh
    }

    private func edit(_ current: Snapshot, cache: inout Snapshot?, _ change: (inout [String: String]) -> Void) -> Bool {
        var current = current
        for attempt in 0..<2 {
            var passwords = current.passwords
            change(&passwords)
            guard passwords != current.passwords else { return true }
            guard let data = try? JSONEncoder().encode(passwords) else { return false }
            let revision = Data(UUID().uuidString.utf8)
            let values: [String: Any] = [kSecValueData as String: data, kSecAttrGeneric as String: revision]
            var query = item
            let status: OSStatus
            let conflict: OSStatus
            if let previous = current.revision {
                query[kSecAttrGeneric as String] = previous
                status = legacy.access.update(query as CFDictionary, values as CFDictionary)
                conflict = errSecItemNotFound
            } else {
                query.merge(values) { _, value in value }
                query[kSecAttrLabel as String] = legacy.service
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                status = legacy.access.add(query as CFDictionary)
                conflict = errSecDuplicateItem
            }
            if status == errSecSuccess {
                cache = Snapshot(revision: revision, passwords: passwords)
                return true
            }
            // A concurrent writer may have changed another account. Retry with its changes included.
            guard status == conflict, attempt == 0,
                  let latest = read(interactive: true, cache: &cache) else { return false }
            current = latest
        }
        return false
    }
}
