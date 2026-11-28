import Combine
import Foundation

nonisolated struct SMBProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let revision: UUID
    let name: String
    let address: URL
    let guest: Bool
    let remembersPassword: Bool
    let connectsAtLaunch: Bool

    var user: String { address.user(percentEncoded: false) ?? "" }
    var shownServer: String {
        let host = URLComponents(url: address, resolvingAgainstBaseURL: false)?.encodedHost ?? ""
        if let port = address.port { return "\(host):\(port)" }
        return host
    }
    var shownSharePath: String { String(address.path(percentEncoded: false).dropFirst()) }
    var shownAddress: String {
        var components = URLComponents(url: address, resolvingAgainstBaseURL: false)
        components?.user = nil
        return components?.string ?? ""
    }
    var title: String { name.isEmpty ? shownAddress : name }
    var browsesShares: Bool { shownSharePath.isEmpty }
    var share: URL {
        guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return address }
        components.percentEncodedPath = Self.pathParts(components).first.map { "/" + $0 } ?? ""
        return components.url ?? address
    }

    func share(named name: String, login: SMBLogin?) -> URL? {
        guard browsesShares, !name.isEmpty,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))),
              Self.validPathComponent(encoded),
              var parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return nil }
        parts.percentEncodedPath = "/" + encoded
        if let login { parts.user = login.user }
        return parts.url
    }

    func folder(in mount: URL) -> URL {
        guard let components = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return mount }
        return Self.pathParts(components).dropFirst().reduce(mount) { folder, part in
            folder.appending(component: part.removingPercentEncoding ?? part, directoryHint: .isDirectory)
        }
    }

    static func make(id: UUID, revision: UUID = UUID(), name: String, address: String, sharePath: String = "",
                     user: String, guest: Bool, remembersPassword: Bool, connectsAtLaunch: Bool) throws -> Self {
        guard case .success(let url) = ServerConnection.url(from: address),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "smb" || parts.scheme == "cifs",
              let host = parts.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !host.contains("\\"), parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              (1...65535).contains(parts.port ?? 445) else {
            throw problem(String(localized: "Enter an SMB address like smb://server/share. Enter login details separately."))
        }
        if !sharePath.isEmpty { parts.path = "/" + sharePath }
        let path = pathParts(parts)
        guard path.allSatisfy(validPathComponent) else {
            throw problem(String(localized: "That isn’t a server address."))
        }
        let user = guest ? "" : user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remembersPassword || (!guest && !user.isEmpty),
              user.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw problem(String(localized: "Enter a user name to save a password."))
        }
        parts.scheme = "smb"
        parts.user = user.isEmpty ? nil : user
        parts.percentEncodedPath = path.map { "/" + $0 }.joined()
        guard let normalized = parts.url else {
            throw problem(String(localized: "That isn’t a server address."))
        }
        return Self(id: id, revision: revision, name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: normalized,
                    guest: guest, remembersPassword: remembersPassword, connectsAtLaunch: connectsAtLaunch)
    }

    fileprivate var isValid: Bool {
        (try? Self.make(id: id, revision: revision, name: name, address: shownAddress, user: user, guest: guest,
                        remembersPassword: remembersPassword, connectsAtLaunch: connectsAtLaunch)) == self
    }

    var credentialAccount: String {
        // A crash during an edit must never make the old profile read a password meant for a new host or account.
        let host = address.host()?.lowercased() ?? ""
        return "\(id.uuidString):\(host.utf8.count):\(host):\(address.port ?? 445):\(user)"
    }

    private static func pathParts(_ address: URLComponents) -> [String] {
        address.percentEncodedPath.split(separator: "/").map(String.init)
    }

    private static func validPathComponent(_ encoded: String) -> Bool {
        guard let part = encoded.removingPercentEncoding else { return false }
        return part != "." && part != ".." && !part.contains("/") && !part.contains("\\")
            && part.rangeOfCharacter(from: .controlCharacters) == nil
    }

    fileprivate static func problem(_ message: String) -> ServerConnection.Problem { .init(message: message) }
}

nonisolated struct SMBMounter: Sendable {
    typealias Mount = @Sendable (URL, String?, Bool, Bool, ServerConnection.Request) async -> ServerMounter.Result
    typealias List = @Sendable (URL, String?, Bool) async throws -> [String]
    let mount: Mount
    let list: List

    init(list: @escaping List = { _, _, _ in throw SMBShareListingError.unavailable }, mount: @escaping Mount) {
        self.list = list
        self.mount = mount
    }

    static let native = SMBMounter(list: SMBShareListing.read) { url, password, guest, interactive, request in
        await ServerConnection.mount(url, request: request, smb: .init(password: password, guest: guest, interactive: interactive))
    }

    static let unavailable = SMBMounter { _, _, _, _, _ in nil }
}

extension Notification.Name {
    static let smbConnectionsChanged = Notification.Name("StrataSMBConnectionsChanged")
}

/// Owns saved SMB definitions, their Keychain items and in-flight native mounts for one browser environment.
final class SMBConnections: ObservableObject {
    private static let storageKey = "smbConnections"
    private let preferences: Prefs
    private let credentials: SMBKeychain
    private let mounter: SMBMounter
    let objectWillChange = ObservableObjectPublisher()
    var notifications: NotificationCenter { preferences.notifications }
    private(set) var profiles: [SMBProfile]
    private let readable: Bool
    private var editing: Set<UUID> = []
    private var started = false
    private(set) var failures: [UUID: String] = [:]

    private struct Attempt {
        let token: UUID
        let interactive: Bool
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }
    private var attempts: [UUID: Attempt] = [:]

    init(preferences: Prefs, credentials: SMBKeychain, mounter: SMBMounter) {
        self.preferences = preferences
        self.credentials = credentials
        self.mounter = mounter
        let saved = preferences.defaults.object(forKey: Self.storageKey)
        let decoded = (saved as? Data).flatMap { try? JSONDecoder().decode([SMBProfile].self, from: $0) }
        let valid = decoded.map { $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }
        readable = saved == nil || valid == true
        profiles = readable ? decoded ?? [] : []
    }

    isolated deinit {
        for attempt in attempts.values {
            attempt.task.cancel()
            for waiter in attempt.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    func profile(_ id: UUID) -> SMBProfile? { profiles.first { $0.id == id } }
    func isConnecting(_ id: UUID) -> Bool { attempts[id] != nil }

    /// New definitions can be configured offline. A blank password in an edit keeps the existing login only
    /// if it still belongs to the same host, port and account.
    func save(_ proposed: SMBProfile, replacing previous: SMBProfile?, password: String) async throws {
        guard proposed.isValid, previous.map({ $0.id == proposed.id && $0.revision != proposed.revision }) ?? true
        else { throw Self.changedProblem() }
        if proposed.remembersPassword, password.isEmpty {
            guard let previous, previous.remembersPassword, proposed.credentialAccount == previous.credentialAccount else {
                throw SMBProfile.problem(String(localized: "Enter the password for this SMB connection."))
            }
        }
        try beginEdit(proposed.id, expecting: previous)
        defer { editing.remove(proposed.id) }
        if proposed.remembersPassword, !password.isEmpty {
            guard !password.utf8.contains(0), await changePassword(for: proposed, to: password) else { throw Self.keychainProblem() }
        }
        if let previous, previous.remembersPassword,
           !proposed.remembersPassword || proposed.credentialAccount != previous.credentialAccount,
           !(await changePassword(for: previous, to: nil)) {
            if proposed.remembersPassword { _ = await changePassword(for: proposed, to: nil) }
            throw Self.keychainProblem()
        }
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == proposed.id }) { updated[index] = proposed }
        else { updated.append(proposed) }
        try publish(updated, changed: proposed.id)
    }

    func remove(_ expected: SMBProfile) async throws {
        try beginEdit(expected.id, expecting: expected)
        defer { editing.remove(expected.id) }
        if expected.remembersPassword, !(await changePassword(for: expected, to: nil)) { throw Self.keychainProblem() }
        try publish(profiles.filter { $0.id != expected.id }, changed: expected.id)
    }

    private func beginEdit(_ id: UUID, expecting previous: SMBProfile?) throws {
        guard readable, profile(id) == previous, editing.insert(id).inserted else { throw Self.changedProblem() }
        // An old mount must stop before the Keychain can return a password for the new login.
        if let attempt = attempts.removeValue(forKey: id) {
            attempt.task.cancel()
            for waiter in attempt.waiters.values { waiter.resume(throwing: CancellationError()) }
            objectWillChange.send()
        }
    }

    private func publish(_ updated: [SMBProfile], changed id: UUID) throws {
        preferences.defaults.set(try JSONEncoder().encode(updated), forKey: Self.storageKey)
        profiles = updated
        failures[id] = nil
        // Release this edit before notifying. An observer can immediately use the committed settings.
        editing.remove(id)
        objectWillChange.send()
        notifications.post(name: .smbConnectionsChanged, object: self)
    }

    @concurrent private func changePassword(for profile: SMBProfile, to password: String?) async -> Bool {
        let account = profile.credentialAccount
        let credentials = credentials
        return await OwnThread.run {
            if let password { return credentials.set(password, account: account) }
            return credentials.delete(account: account)
        }
    }

    private static func changedProblem() -> ServerConnection.Problem {
        SMBProfile.problem(String(localized: "The saved SMB connection changed. Reopen its settings and try again."))
    }

    private static func keychainProblem() -> ServerConnection.Problem {
        SMBProfile.problem(String(localized: "Strata couldn’t update the SMB password in the Keychain."))
    }

    /// Startup requests keep their own tickets and never open a window, change a pane or prompt for login.
    @discardableResult
    func connectAtLaunch() -> [Task<Void, Never>] {
        guard !started else { return [] }
        started = true
        return profiles.filter(\.connectsAtLaunch).map { profile in
            Task { [weak self] in _ = try? await self?.connect(profile, interactive: false) }
        }
    }

    func connect(_ profile: SMBProfile, interactive: Bool = true) async throws -> URL {
        try check(profile)
        // Let an interactive caller share a running startup mount. If it fails without UI, the caller can prompt.
        if interactive, attempts[profile.id]?.interactive == false {
            do { return try await join(profile, interactive: false) }
            catch is CancellationError { throw CancellationError() }
            catch { try check(profile) }
        }
        return try await join(profile, interactive: interactive)
    }

    func listShares(_ profile: SMBProfile, login: SMBLogin?) async throws -> [String] {
        try check(profile)
        let password = await Self.password(for: profile, credentials: credentials, login: login, interactive: true)
        try check(profile)
        var address = URLComponents(url: profile.share, resolvingAgainstBaseURL: false)
        if let login { address?.user = login.user }
        guard profile.browsesShares, let url = address?.url else { throw SMBShareListingError.unavailable }
        let names = try await Self.readShares(of: profile, at: url, password: password, list: mounter.list)
        try check(profile)
        return names
    }

    @concurrent private static func readShares(of profile: SMBProfile, at url: URL, password: String?,
                                               list: SMBMounter.List) async throws -> [String] {
        let names = try await list(url, password, profile.guest)
        return Set(names.filter { profile.share(named: $0, login: nil) != nil })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func connect(to name: String, on profile: SMBProfile, login: SMBLogin?) async throws -> URL {
        try check(profile)
        guard let share = profile.share(named: name, login: login) else { throw SMBShareListingError.unavailable }
        let password = await Self.password(for: profile, credentials: credentials, login: login, interactive: true)
        try check(profile)
        let folder = try await Self.mount(share, password: password, guest: profile.guest, interactive: true, mounter: mounter)
        try check(profile)
        return folder
    }

    private func check(_ profile: SMBProfile) throws {
        try Task.checkCancellation()
        guard self.profile(profile.id) == profile, !editing.contains(profile.id) else { throw CancellationError() }
    }

    private func join(_ profile: SMBProfile, interactive: Bool) async throws -> URL {
        let id = profile.id, ticket = UUID()
        let result: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                guard !Task.isCancelled else { return waiter.resume(throwing: CancellationError()) }
                if attempts[id] != nil {
                    attempts[id]?.waiters[ticket] = waiter
                    return
                }
                let mounter = mounter, credentials = credentials, token = UUID()
                let task = Task { [weak self] in
                    do {
                        let folder = try await Self.mount(profile, interactive: interactive, mounter: mounter, credentials: credentials)
                        self?.finish(id: id, token: token, result: .success(folder))
                    } catch {
                        self?.finish(id: id, token: token, result: .failure(error))
                    }
                }
                attempts[id] = Attempt(token: token, interactive: interactive, task: task, waiters: [ticket: waiter])
                failures[id] = nil
                objectWillChange.send()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id, ticket: ticket) }
        }
        try check(profile)
        return result
    }

    private func cancel(id: UUID, ticket: UUID) {
        guard let waiter = attempts[id]?.waiters.removeValue(forKey: ticket) else { return }
        if attempts[id]?.waiters.isEmpty == true {
            attempts.removeValue(forKey: id)?.task.cancel()
            objectWillChange.send()
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finish(id: UUID, token: UUID, result: Result<URL, Error>) {
        guard attempts[id]?.token == token, let attempt = attempts.removeValue(forKey: id) else { return }
        if case .failure(let error as ServerConnection.Problem) = result { failures[id] = error.message }
        for waiter in attempt.waiters.values { waiter.resume(with: result) }
        objectWillChange.send()
    }

    @concurrent private static func mount(_ profile: SMBProfile, interactive: Bool, mounter: SMBMounter,
                                          credentials: SMBKeychain) async throws -> URL {
        let password = await password(for: profile, credentials: credentials, login: nil, interactive: interactive)
        let root = try await mount(profile.share, password: password, guest: profile.guest, interactive: interactive, mounter: mounter)
        return profile.folder(in: root)
    }

    @concurrent private static func password(for profile: SMBProfile, credentials: SMBKeychain, login: SMBLogin?,
                                             interactive: Bool) async -> String? {
        if let login { return login.password }
        guard profile.remembersPassword else { return nil }
        return await OwnThread.runUnlessCancelled {
            credentials.secret(account: profile.credentialAccount, interactive: interactive)
        } ?? nil
    }

    @concurrent private static func mount(_ share: URL, password: String?, guest: Bool, interactive: Bool,
                                          mounter: SMBMounter) async throws -> URL {
        let request = ServerConnection.Request()
        try Task.checkCancellation()
        let result = await withTaskCancellationHandler {
            await mounter.mount(share, password, guest, interactive, request)
        } onCancel: { request.cancel() }
        switch result {
        case .success(let root): return root
        case .failure(let problem): throw problem
        case nil:
            if interactive || Task.isCancelled { throw CancellationError() }
            throw SMBProfile.problem(String(localized: "The SMB share couldn’t connect at launch."))
        }
    }

    func mountedVolume(for profile: SMBProfile, in volumes: [Place]) -> Place? {
        let matching = volumes.filter { volume in
            guard let address = volume.remountAddress else { return false }
            return ServerConnection.matchesSMB(address, share: profile.share, guest: profile.guest)
        }
        return matching.count == 1 ? matching.first : nil
    }

    func contains(_ folder: URL, profile: SMBProfile, in volumes: [Place]) -> Bool {
        guard let mount = mountedVolume(for: profile, in: volumes) else { return false }
        let root = profile.folder(in: mount.url).fileViewKey, path = folder.fileViewKey
        return path == root || path.hasPrefix(root + "/")
    }
}
