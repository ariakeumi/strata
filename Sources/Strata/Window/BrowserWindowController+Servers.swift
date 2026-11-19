import AppKit

/// Connect to Server, a saved server's sheet, connecting to one and disconnecting.
extension BrowserWindowController {
    /// Go ▸ Connect to Server…: mounts a share (macOS asks for the login), then shows it.
    @objc func connectToServer(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        contentViewController?.presentAsSheet(serverController())
    }

    /// Edit… for a saved SFTP server or bucket: the same sheet, filled in.
    func editServer(_ server: RemoteServer) {
        guard let window, window.attachedSheet == nil else { return }
        contentViewController?.presentAsSheet(serverController(editing: server))
    }

    /// Build the native sheet with the same server owner as the window, including when editing saved settings.
    func serverController(editing server: RemoteServer? = nil) -> ConnectToServerController {
        let origin = pane
        let controller = ConnectToServerController(editing: server, settings: services.connectionSettings,
                                                   mounts: ServerMountSession(mounter: .live),
                                                   connections: services.remote.connections)
        controller.onManageSMB = { [show = services.showSetting] in show(.smbConnections) }
        controller.onConnected = { [weak self, weak origin] mounted in
            guard let self, !isClosed, let origin, panes.contains(where: { $0 === origin }) else { return }
            go(.folder(mounted.lexicallyStandardized), in: origin)
        }
        controller.onServer = { [weak self, weak origin] server in
            guard let self, let origin else { return }
            openServer(server, in: origin)
        }
        return controller
    }

    /// Connects to `server` (saying so over the folder, with Cancel) and shows where browsing starts: its saved
    /// folder, or where the login starts (a bucket's top).
    @discardableResult
    func openServer(_ server: RemoteServer, in origin: Pane? = nil) -> Task<Void, Never> {
        let browsing = services.remoteBrowsing
        return openFolder(in: origin,
                          notice: .init(symbol: "network", text: String(localized: "Connecting to “\(server.name)”…", comment: "A server's name")),
                          operation: { try await browsing.open(server) }) { [weak self] error in
            guard let self, let window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t connect to “\(server.name)”", comment: "A server's name")
            alert.informativeText = RemoteFiles.message(for: error)
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    /// Ends the connection to `server` and forgets its files here; panes showing them go home.
    func disconnectServer(_ server: RemoteServer) {
        services.remote.connections.disconnect(server)
    }

    @discardableResult
    func openSMB(_ id: UUID) -> Task<Void, Never>? {
        let connections = services.smb
        guard !isClosed, let profile = connections.profile(id) else { return nil }
        if profile.browsesShares {
            let origin = pane
            go(.smb(id, title: profile.title), in: origin)
            return origin.opening.task
        }
        return mountSMB(in: pane, name: profile.title) { try await connections.connect(profile) }
    }

    func showSMBShares(_ id: UUID, in origin: Pane, login: SMBLogin? = nil) {
        origin.opening.cancel()
        let connections = services.smb
        let destination = origin.destination
        let profile = connections.profile(id).flatMap { $0.browsesShares ? $0 : nil }
        let root = profile.flatMap { URL(string: $0.shownAddress) }
        let shares = origin.browser.showSMBShareList(at: root) { [weak self, weak origin] in
            guard let self, let origin, origin.destination == destination else { return }
            showSMBShares(id, in: origin, login: login)
            if pane === origin { focusList() }
        }
        guard let profile else {
            origin.browser.emptyState.show(symbol: "network", title: String(localized: "The saved SMB connection changed. Reopen its settings and try again."))
            if pane === origin { refreshOpeningNotice() }
            return
        }
        origin.opening.open(operation: { try await connections.listShares(profile, login: login) }) {
            [weak self, weak origin, weak shares] result in
            guard let self, !isClosed, let origin, let shares, origin.browser.smbShares === shares,
                  origin.destination == destination, panes.contains(where: { $0 === origin }) else { return }
            switch result {
            case .success(let names):
                origin.browser.publishSMBShares(names) { [weak self, weak origin, weak shares] name in
                    guard let self, let origin, let shares, origin.browser.smbShares === shares,
                          connections.profile(id) == profile else { return }
                    mountSMB(in: origin, name: name) { try await connections.connect(to: name, on: profile, login: login) }
                }
            case .failure(let error):
                showSMBListingError(error, profile: profile, in: origin, shares: shares)
            }
        }
        if pane === origin { refreshOpeningNotice() }
    }

    private func showSMBListingError(_ error: Error, profile: SMBProfile, in origin: Pane, shares: SMBSharePage) {
        let listingError = error as? SMBShareListingError
        let title = String(localized: "Couldn’t connect to “\(profile.title)”", comment: "A server's name")
        if listingError?.requiresLogin == true, !profile.guest {
            origin.browser.emptyState.show(symbol: "network", title: title,
                message: listingError?.problem?.message ?? "",
                button: (String(localized: "Connect", comment: "Button: connect to the server"), { [weak self, weak origin, weak shares] in
                    guard let self, let origin, let shares else { return }
                    requestSMBLogin(for: profile, in: origin, shares: shares)
                }))
        } else {
            let message = (error as? ServerConnection.Problem)?.message ?? listingError?.problem?.message ?? ""
            origin.browser.emptyState.show(symbol: "network", title: title, message: message,
                button: (String(localized: "Try Again"), { [weak shares] in shares?.onReload() }))
        }
    }

    private func requestSMBLogin(for profile: SMBProfile, in origin: Pane, shares: SMBSharePage) {
        guard !isClosed, let window, window.attachedSheet == nil, origin.browser.smbShares === shares,
              services.smb.profile(profile.id) == profile else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Connecting to “\(profile.title)”…", comment: "A server's name")
        let user = NSTextField(string: profile.user)
        user.placeholderString = String(localized: "User Name")
        user.setAccessibilityLabel(user.placeholderString)
        let password = NSSecureTextField()
        password.placeholderString = String(localized: "Password")
        password.setAccessibilityLabel(password.placeholderString)
        let fields = NSStackView(views: [user, password])
        fields.orientation = .vertical
        fields.alignment = .leading
        for field in [user, password] { field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        fields.frame.size = fields.fittingSize
        alert.accessoryView = fields
        alert.addButton(withTitle: String(localized: "Connect", comment: "Button: connect to the server"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = profile.user.isEmpty ? user : password
        alert.beginSheetModal(for: window) { [weak self, weak origin, weak shares] response in
            guard response == .alertFirstButtonReturn, let self, !isClosed, let origin, let shares,
                  panes.contains(where: { $0 === origin }), origin.browser.smbShares === shares,
                  services.smb.profile(profile.id) == profile else { return }
            let name = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil, !password.stringValue.utf8.contains(0) else { return }
            showSMBShares(profile.id, in: origin, login: SMBLogin(user: name, password: password.stringValue))
            if pane === origin { focusList() }
        }
    }

    @discardableResult
    private func mountSMB(in origin: Pane, name: String,
                          operation: @escaping @Sendable () async throws -> URL) -> Task<Void, Never> {
        openFolder(in: origin,
                   notice: .init(symbol: "network", text: String(localized: "Connecting to “\(name)”…", comment: "A server's name")),
                   operation: operation) { [weak self] error in
            guard let self, let problem = error as? ServerConnection.Problem,
                  let window, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t connect to “\(name)”", comment: "A server's name")
            alert.informativeText = problem.message
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
}
