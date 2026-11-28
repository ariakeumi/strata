import Foundation
import Security
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct RemoteKeychainTests {
    nonisolated private struct Identity: Hashable, Sendable {
        var service = "Strata S3"
        var account: String
        var kind = kSecClassGenericPassword as String
    }

    nonisolated private struct Item: Equatable, Sendable {
        let identity = UUID()
        var data: Data
        var label: String
        var accessible = kSecAttrAccessibleWhenUnlocked as String
        var revision: Data?

        init(_ value: String, label: String = "Fixture") {
            data = Data(value.utf8)
            self.label = label
        }
    }

    nonisolated private struct Call: Equatable, Sendable {
        enum Operation: Sendable { case read, add, update, delete }
        let operation: Operation
        let queryKeys: Set<String>
        let attributeKeys: Set<String>
        let returnsData: Bool?
        let matchLimit: String?
        let account: String?
        let authenticationUI: String?
    }

    /// A model of the four Security calls, including matching every item an update/delete query selects. It never
    /// calls Security: omitted identity keys really do select neighboring fixtures, so scope assertions catch that.
    nonisolated private final class Keychain: Sendable {
        struct State: Sendable {
            var items: [Identity: Item] = [:]
            var calls: [Call] = []
            var updateError: OSStatus?
            var addError: OSStatus?
            var readError: OSStatus?
            var wrongReadType = false
            var concurrentCreation: Item?
            var updateErrorAfterCreation: OSStatus?
            var concurrentUpdate: Item?
            var restrictedItems: Set<Identity> = []
            var forbiddenDeletions: Set<Identity> = []
        }
        let state: Mutex<State>
        init(_ state: State = State()) { self.state = Mutex(state) }
        var items: [Identity: Item] { state.withLock { $0.items } }
        var calls: [Call] { state.withLock { $0.calls } }
        var access: KeychainAccess {
            KeychainAccess(copy: { self.read($0) }, add: { self.add($0) },
                           update: { self.update($0, $1) }, delete: { self.delete($0) })
        }

        private func matches(_ key: Identity, _ item: Item, _ query: [String: Any]) -> Bool {
            [(kSecClass as String, key.kind), (kSecAttrService as String, key.service), (kSecAttrAccount as String, key.account)]
                .allSatisfy { field, value in query[field] == nil || query[field] as? String == value }
                && (query[kSecAttrGeneric as String] == nil || query[kSecAttrGeneric as String] as? Data == item.revision)
        }

        private func record(_ operation: Call.Operation, _ query: [String: Any], _ attributes: [String: Any] = [:]) -> Call {
            Call(operation: operation, queryKeys: Set(query.keys), attributeKeys: Set(attributes.keys),
                 returnsData: query[kSecReturnData as String] as? Bool,
                 matchLimit: query[kSecMatchLimit as String] as? String,
                 account: query[kSecAttrAccount as String] as? String,
                 authenticationUI: query[kSecUseAuthenticationUI as String] as? String)
        }

        private func read(_ raw: CFDictionary) -> (OSStatus, CFTypeRef?) {
            let query = raw as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.read, query))
                if let error = state.readError { return (error, Data("Untrusted error result".utf8) as CFData) }
                if state.wrongReadType { return (errSecSuccess, "Not credential data" as CFString) }
                guard let (key, item) = state.items.first(where: { matches($0.key, $0.value, query) })
                else { return (errSecItemNotFound, nil) }
                let returnsData = query[kSecReturnData as String] as? Bool == true
                if returnsData, state.restrictedItems.contains(key),
                   query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUISkip as String {
                    return (errSecItemNotFound, nil)
                }
                if query[kSecReturnAttributes as String] as? Bool == true {
                    var attributes: [String: Any] = [:]
                    attributes[kSecAttrGeneric as String] = item.revision
                    if returnsData { attributes[kSecValueData as String] = item.data }
                    return (errSecSuccess, attributes as CFDictionary)
                }
                return (errSecSuccess, item.data as CFData)
            }
        }

        private func add(_ raw: CFDictionary) -> OSStatus {
            let item = raw as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.add, item))
                if let error = state.addError { return error }
                guard let service = item[kSecAttrService as String] as? String,
                      let account = item[kSecAttrAccount as String] as? String,
                      let kind = item[kSecClass as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let label = item[kSecAttrLabel as String] as? String,
                      let accessible = item[kSecAttrAccessible as String] as? String else { return errSecParam }
                let key = Identity(service: service, account: account, kind: kind)
                if let concurrent = state.concurrentCreation {
                    state.concurrentCreation = nil
                    state.items[key] = concurrent
                    state.updateError = state.updateErrorAfterCreation
                    return errSecDuplicateItem
                }
                guard state.items[key] == nil else { return errSecDuplicateItem }
                var made = Item("")
                made.data = data; made.label = label; made.accessible = accessible
                made.revision = item[kSecAttrGeneric as String] as? Data
                state.items[key] = made
                return errSecSuccess
            }
        }

        private func update(_ raw: CFDictionary, _ rawAttributes: CFDictionary) -> OSStatus {
            let query = raw as! [String: Any], attributes = rawAttributes as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.update, query, attributes))
                if let error = state.updateError { return error }
                guard query[kSecReturnData as String] == nil, query[kSecMatchLimit as String] == nil,
                      let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
                if let concurrent = state.concurrentUpdate,
                   let key = state.items.first(where: { matches($0.key, $0.value, query) })?.key {
                    state.concurrentUpdate = nil
                    state.items[key] = concurrent
                }
                let matching = state.items.filter { matches($0.key, $0.value, query) }.keys
                guard !matching.isEmpty else { return errSecItemNotFound }
                for key in matching {
                    state.items[key]?.data = data
                    if let label = attributes[kSecAttrLabel as String] as? String { state.items[key]?.label = label }
                    if let revision = attributes[kSecAttrGeneric as String] as? Data { state.items[key]?.revision = revision }
                    if let accessibility = attributes[kSecAttrAccessible as String] as? String {
                        state.items[key]?.accessible = accessibility
                    }
                }
                return errSecSuccess
            }
        }

        private func delete(_ raw: CFDictionary) -> OSStatus {
            let query = raw as! [String: Any]
            return state.withLock { state in
                state.calls.append(record(.delete, query))
                let matching = state.items.filter { matches($0.key, $0.value, query) }.keys
                if matching.contains(where: state.forbiddenDeletions.contains) { return errSecAuthFailed }
                for key in matching { state.items[key] = nil }
                return matching.isEmpty ? errSecItemNotFound : errSecSuccess
            }
        }
    }

    private let server = RemoteServer(id: UUID().uuidString, kind: .s3, name: "Fixture", host: "s3.eu-west-1.amazonaws.com",
                                      bucket: "fixture", region: "eu-west-1", accessKeyID: "FIXTUREKEY")
    private var key: Identity { Identity(account: server.id) }
    private var neighbors: [Identity: Item] {
        [Identity(account: server.id + "-other"): Item("Neighbor"),
         Identity(service: "Another service", account: server.id): Item("Other service"),
         Identity(account: server.id, kind: kSecClassInternetPassword as String): Item("Other class")]
    }
    private var identityKeys: Set<String> { [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String] }

    @Test func replacingASecretKeepsTheOriginalWhenSecurityRefusesTheUpdate() {
        for error in [errSecAuthFailed, errSecInteractionNotAllowed, errSecParam] {
            var items = neighbors
            items[key] = Item("Working secret")
            let fixture = Keychain(.init(items: items, updateError: error, addError: error))
            let store = RemoteKeychain(access: fixture.access)
            #expect(!store.setSecret("Replacement", for: server))
            #expect(fixture.items == items)
            #expect(fixture.calls.map(\.operation) == [.update])
        }
    }

    @Test func creationAndReplacementKeepExactIdentityAndNativeProtection() throws {
        let original = neighbors
        let fixture = Keychain(.init(items: original)), store = RemoteKeychain(access: fixture.access)
        #expect(store.setSecret("First", for: server))
        var first = try #require(fixture.items[key])
        #expect(first.data == Data("First".utf8))
        #expect(first.label == "Strata S3: fixture")
        #expect(first.accessible == kSecAttrAccessibleWhenUnlocked as String)
        #expect(fixture.items.filter { $0.key != key } == original)
        first.accessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        fixture.state.withLock { $0.items[key] = first }
        var edited = server
        edited.name = "Renamed"; edited.bucket = "renamed-bucket"
        #expect(store.setSecret("Updated ☃", for: edited))
        var expected = first
        expected.data = Data("Updated ☃".utf8); expected.label = "Strata S3: renamed-bucket"
        #expect(fixture.items[key] == expected)
        #expect(fixture.items.filter { $0.key != key } == original)
        #expect(fixture.calls.map(\.operation) == [.update, .add, .update])
        for call in fixture.calls where call.operation == .update {
            #expect(call.queryKeys == identityKeys)
            #expect(call.attributeKeys == [kSecValueData as String, kSecAttrLabel as String])
        }
        let add = try #require(fixture.calls.first { $0.operation == .add })
        #expect(add.queryKeys == identityKeys.union([kSecValueData as String, kSecAttrLabel as String, kSecAttrAccessible as String]))
    }

    @Test func anotherCreatorIsUpdatedInPlaceAndFailedRetriesLeaveItsItemIntact() throws {
        let neighbors = self.neighbors
        for failure: OSStatus? in [nil, errSecAuthFailed, errSecItemNotFound] {
            let concurrent = Item("Created concurrently", label: "Keep unless update succeeds")
            let fixture = Keychain(.init(items: neighbors, concurrentCreation: concurrent, updateErrorAfterCreation: failure))
            let store = RemoteKeychain(access: fixture.access)
            #expect(store.setSecret("Wanted", for: server) == (failure == nil))
            var expected = concurrent
            if failure == nil { expected.data = Data("Wanted".utf8); expected.label = "Strata S3: fixture" }
            #expect(fixture.items[key] == expected)
            #expect(fixture.items.filter { $0.key != key } == neighbors)
            #expect(fixture.calls.map(\.operation) == [.update, .add, .update])
        }
    }

    @Test func failedNewItemsNeverChangeExistingCredentials() {
        let neighbors = self.neighbors
        for error in [errSecAuthFailed, errSecInteractionNotAllowed, errSecParam] {
            let fixture = Keychain(.init(items: neighbors, addError: error))
            let store = RemoteKeychain(access: fixture.access)
            #expect(!store.setSecret("Rejected", for: server))
            #expect(fixture.items == neighbors)
            #expect(fixture.calls.map(\.operation) == [.update, .add])
        }
    }

    @Test func readsAndDeletesStayWithTheirStoreAndExactServer() {
        let neighbors = self.neighbors
        var items = neighbors
        items[key] = Item("First")
        let first = Keychain(.init(items: items))
        var otherItems = neighbors
        otherItems[key] = Item("Second")
        let second = Keychain(.init(items: otherItems))
        let left = RemoteKeychain(access: first.access), right = RemoteKeychain(access: second.access)
        #expect(left.secret(for: server) == "First" && right.secret(for: server) == "Second")
        left.delete(server)
        #expect(first.items == neighbors && second.items == otherItems)
        #expect(left.secret(for: server) == nil && right.secret(for: server) == "Second")
        left.delete(server)
        #expect(first.items == neighbors && second.items == otherItems)
        for call in first.calls {
            switch call.operation {
            case .read:
                #expect(call.queryKeys == identityKeys.union([kSecReturnData as String, kSecMatchLimit as String]))
                #expect(call.returnsData == true && call.matchLimit == kSecMatchLimitOne as String)
            case .delete: #expect(call.queryKeys == identityKeys)
            default: Issue.record("A read or deletion unexpectedly wrote a credential")
            }
        }
    }

    @Test func unreadableCredentialsNeverChangeTheStoreOrConstructAnAuthenticatedBackend() throws {
        var bad = Item("")
        bad.data = Data([0xff, 0xfe])
        let states = [Keychain.State(), .init(items: [key: Item("Saved")], readError: errSecAuthFailed),
                      .init(items: [key: Item("Saved")], wrongReadType: true), .init(items: [key: bad])]
        for state in states {
            let fixture = Keychain(state), store = RemoteKeychain(access: fixture.access)
            #expect(store.secret(for: server) == nil)
            #expect(throws: RemoteError.noSecret) { try S3Backend(server, credentials: store) }
            #expect(fixture.items == state.items)
            #expect(fixture.calls.allSatisfy { $0.operation == .read })
        }
        let fixture = Keychain(.init(items: [key: Item("Fixture secret")]))
        let backend = try S3Backend(server, credentials: RemoteKeychain(access: fixture.access))
        #expect(backend.isAlive)
        #expect(fixture.calls.map(\.operation) == [.read])
        #expect(fixture.items[key]?.data == Data("Fixture secret".utf8))
        backend.close()
    }

    private let smbBundle = Identity(service: "Strata SMB", account: "saved-passwords")

    private func smbPasswords(in keychain: Keychain) throws -> [String: String] {
        let item = try #require(keychain.items[smbBundle])
        return try JSONDecoder().decode([String: String].self, from: item.data)
    }

    @Test func smbPasswordsShareOneKeychainItemAndOneReadAtStartup() async throws {
        let preferences = try Prefs.isolated()
        func profile(host: String = "nas", id: UUID) throws -> SMBProfile {
            try SMBProfile.make(id: id, name: "", address: "smb://\(host)/team", user: "amy", guest: false,
                                remembersPassword: true, connectsAtLaunch: true)
        }
        let saved = try profile(id: UUID())
        let second = try profile(host: "second", id: UUID())
        let s3 = Identity(account: saved.credentialAccount)
        let other = Identity(service: "Strata SMB", account: saved.credentialAccount + "-other")
        let neighbors = [s3: Item("S3 secret"), other: Item("Other SMB password")]
        let keychain = Keychain(.init(items: neighbors))
        let expected = [saved.share: "Fixture password", second.share: "Second fixture password"]
        let mounted = Mutex([URL: String]())
        let mounter = SMBMounter { url, password, guest, interactive, _ in
            #expect(password == expected[url] && !guest && !interactive)
            mounted.withLock { $0[url] = password }
            return .success(URL(filePath: "/Volumes/Fixture"))
        }
        let first = SMBConnections(preferences: preferences, credentials: RemoteKeychain(access: keychain.access).smb, mounter: mounter)
        async let firstSave: Void = first.save(saved, replacing: nil, password: "Fixture password")
        async let secondSave: Void = first.save(second, replacing: nil, password: "Second fixture password")
        _ = try await (firstSave, secondSave)
        let data = try #require(preferences.defaults.data(forKey: "smbConnections"))
        #expect(!String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("fixture password"))
        #expect(try smbPasswords(in: keychain) == [saved.credentialAccount: "Fixture password",
                                                  second.credentialAccount: "Second fixture password"])
        #expect(keychain.items.filter { $0.key != smbBundle } == neighbors)

        let reopened = SMBConnections(preferences: preferences, credentials: RemoteKeychain(access: keychain.access).smb, mounter: mounter)
        #expect(Set(reopened.profiles.map(\.id)) == [saved.id, second.id])
        let beforeLaunch = keychain.calls.count
        for task in reopened.connectAtLaunch() { await task.value }
        #expect(mounted.withLock { $0 } == expected)
        let launchCalls = keychain.calls.dropFirst(beforeLaunch)
        #expect(launchCalls.allSatisfy { $0.operation == .read && $0.authenticationUI == kSecUseAuthenticationUISkip as String })
        #expect(launchCalls.filter { $0.returnsData == true }.map(\.account) == [smbBundle.account])

        let edited = try profile(id: saved.id)
        #expect(edited.revision != saved.revision)
        try await reopened.save(edited, replacing: saved, password: "")
        let moved = try profile(host: "other", id: saved.id)
        await #expect(throws: ServerConnection.Problem.self) {
            try await reopened.save(moved, replacing: edited, password: "")
        }
        await #expect(throws: ServerConnection.Problem.self) { try await reopened.remove(saved) }
        keychain.state.withLock { $0.updateError = errSecAuthFailed }
        await #expect(throws: ServerConnection.Problem.self) {
            try await reopened.save(moved, replacing: edited, password: "Rejected")
        }
        #expect(reopened.profile(saved.id) == edited)
        #expect(moved.credentialAccount != saved.credentialAccount)
        keychain.state.withLock { $0.updateError = nil }
        try await reopened.save(moved, replacing: edited, password: "Password for other host")
        #expect(try smbPasswords(in: keychain) == [moved.credentialAccount: "Password for other host",
                                                  second.credentialAccount: "Second fixture password"])
        try await reopened.remove(moved)
        #expect(try smbPasswords(in: keychain) == [second.credentialAccount: "Second fixture password"])
        try await reopened.remove(second)
        #expect(try smbPasswords(in: keychain).isEmpty)
        #expect(keychain.items.filter { $0.key != smbBundle } == neighbors)
        #expect(reopened.profiles.isEmpty)
    }

    @Test func smbMigrationKeepsLegacyPasswordsUntilTheSharedItemIsSaved() throws {
        let first = Identity(service: "Strata SMB", account: "old-first")
        let second = Identity(service: "Strata SMB", account: "old-second")
        let s3 = Identity(account: first.account)
        let s3Item = Item("S3 secret")
        let items = [first: Item("First legacy"), second: Item("Second legacy"), s3: s3Item]
        let keychain = Keychain(.init(items: items, addError: errSecAuthFailed, restrictedItems: [first]))
        let store = RemoteKeychain(access: keychain.access).smb
        #expect(store.secret(account: first.account, interactive: false) == nil)
        #expect(store.secret(account: second.account, interactive: false) == "Second legacy")
        #expect(keychain.calls.allSatisfy { $0.operation == .read })
        #expect(store.secret(account: first.account, interactive: true) == "First legacy")
        #expect(keychain.items == items)
        keychain.state.withLock { $0.addError = nil }

        #expect(store.secret(account: first.account, interactive: true) == "First legacy")
        #expect(try smbPasswords(in: keychain) == [first.account: "First legacy"])
        #expect(keychain.items[first] == nil && keychain.items[second] == items[second])
        #expect(store.secret(account: second.account, interactive: true) == "Second legacy")
        #expect(keychain.items.filter { $0.key != smbBundle } == [s3: s3Item])

        _ = keychain.state.withLock { $0.restrictedItems.insert(smbBundle) }
        let reopened = RemoteKeychain(access: keychain.access).smb
        #expect(reopened.secret(account: first.account, interactive: false) == nil)
        let before = keychain.calls.count
        #expect(reopened.secret(account: first.account, interactive: true) == "First legacy")
        #expect(reopened.secret(account: second.account, interactive: true) == "Second legacy")
        #expect(keychain.calls.dropFirst(before).filter { $0.returnsData == true }.map(\.account) == [smbBundle.account])
    }

    @Test func smbDeletionCannotRestoreAStaleLegacyPassword() throws {
        let legacy = Identity(service: "Strata SMB", account: "account")
        let old = Item("Old password")
        let keychain = Keychain(.init(items: [legacy: old], forbiddenDeletions: [legacy]))
        let store = RemoteKeychain(access: keychain.access).smb
        #expect(store.set("Current password", account: legacy.account))
        #expect(keychain.items[legacy] == old)
        #expect(store.secret(account: legacy.account, interactive: true) == "Current password")
        #expect(!store.delete(account: legacy.account))
        #expect(try smbPasswords(in: keychain) == [legacy.account: "Current password"])
        _ = keychain.state.withLock { $0.forbiddenDeletions.remove(legacy) }
        #expect(store.delete(account: legacy.account))
        #expect(store.secret(account: legacy.account, interactive: true) == nil)
        #expect(keychain.items[legacy] == nil)
    }

    @Test func smbEditsPreserveAConcurrentUpdateToAnotherPassword() throws {
        let keychain = Keychain()
        let store = RemoteKeychain(access: keychain.access).smb
        #expect(store.set("First", account: "first"))
        var concurrent = try #require(keychain.items[smbBundle])
        concurrent.revision = Data("new revision".utf8)
        concurrent.data = try JSONEncoder().encode(["first": "First", "second": "Second"])
        keychain.state.withLock { $0.concurrentUpdate = concurrent }
        #expect(store.set("Edited", account: "first"))
        #expect(try smbPasswords(in: keychain) == ["first": "Edited", "second": "Second"])
        #expect(keychain.items[smbBundle]?.identity == concurrent.identity)
    }

    @Test func anUnreadableSMBBundleDoesNotFallBackToLegacyOrGetOverwritten() {
        var corrupt = Item("Invalid JSON")
        corrupt.revision = Data("revision".utf8)
        let legacy = Identity(service: "Strata SMB", account: "legacy")
        let items = [smbBundle: corrupt, legacy: Item("Old password")]
        let keychain = Keychain(.init(items: items))
        let store = RemoteKeychain(access: keychain.access).smb
        #expect(store.secret(account: legacy.account, interactive: true) == nil)
        #expect(!store.set("Rejected", account: legacy.account))
        #expect(!store.delete(account: legacy.account))
        #expect(keychain.items == items)
        #expect(keychain.calls.allSatisfy { $0.operation == .read && $0.account == smbBundle.account })
    }
}
