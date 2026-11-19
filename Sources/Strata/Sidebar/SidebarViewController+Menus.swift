import AppKit

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outline.item(atRow: outline.clickedRow)
        guard let item = clicked as? SidebarItem else {
            addVisibilityItems(clicked as? SidebarSection, to: menu)
            return
        }
        if case .recents = item.target {
            addHideItem(to: menu, action: #selector(hideRecents(_:)))
            return
        }
        if case .containers = item.target { return }
        if case .workspace(let name) = item.target {
            addWorkspaceItems(name, to: menu)
            return
        }
        if case .smb(let id) = item.target {
            addSMBMenu(to: menu, id: id, connect: #selector(openSMB(_:)), manage: #selector(manageSMB(_:)), target: self)
            return
        }
        if case .server(let id) = item.target, let server = services.remote.servers.server(id: id) {
            addServerItems(server, to: menu)
            return
        }
        // Tags you added can leave the sidebar; the seven colored ones stay, like Finder's.
        if item.tint != nil {
            let name = item.tagName ?? item.title
            let isStandard = FinderTag.standard.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if !isStandard {
                let remove = NSMenuItem(title: String(localized: "Remove “\(item.title)” from Sidebar"), action: #selector(forgetTag(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = name
                menu.addItem(remove)
            }
            return
        }
        if case .search(let search) = item.target {
            let remove = NSMenuItem(title: String(localized: "Remove “\(search.name)”", comment: "Sidebar menu: remove a saved search"), action: #selector(removeSearch(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = SavedSearchBox(search: search)
            menu.addItem(remove)
            return
        }
        guard let url = item.url else { return }
        if Trash.isTrash(url) {
            add("Open in New Tab", #selector(openInNewTab(_:)), url)
            menu.addItem(.separator())
            let empty = NSMenuItem(title: String(localized: "Empty Trash…"), action: #selector(AppDelegate.emptyTrash(_:)), keyEquivalent: "")
            menu.addItem(empty)
            return
        }
        let favorite = isFavorite(item)
        add("Open in New Tab", #selector(openInNewTab(_:)), url)
        add("Copy Path", #selector(copyItemPath(_:)), url)
        menu.addItem(.separator())
        if item.groupID != nil {
            addHideItem(to: menu, action: #selector(removeGroupFolder(_:)), representedObject: item)
            if canAddToFavorites(item) { add("Add to Favorites", #selector(addFavorite(_:)), url) }
        } else if favorite {
            add("Remove from Sidebar", #selector(removeFavorite(_:)), url)
        } else if canAddToFavorites(item) {
            add("Add to Favorites", #selector(addFavorite(_:)), url)
        }
        if isFrequent(item) {
            add("Remove from Frequent", #selector(removeFrequent(_:)), url)
        }
        if item.isEjectable {
            menu.addItem(.separator())
            add("Eject “\(item.title)”", #selector(ejectItem(_:)), url)
        }
    }

    private func addHideItem(to menu: NSMenu, action: Selector, representedObject: Any? = nil) {
        let remove = NSMenuItem(title: String(localized: "Remove from Sidebar"), action: action, keyEquivalent: "")
        remove.target = self
        remove.representedObject = representedObject
        menu.addItem(remove)
    }

    private func addVisibilityItems(_ section: SidebarSection?, to menu: NSMenu) {
        let create = NSMenuItem(title: String(localized: "New Group…"), action: #selector(newSidebarGroup(_:)), keyEquivalent: "")
        create.target = self
        menu.addItem(create)
        if let section {
            if let id = section.groupID {
                let rename = NSMenuItem(title: String(localized: "Rename…"), action: #selector(renameSidebarGroup(_:)), keyEquivalent: "")
                rename.target = self
                rename.representedObject = id
                menu.addItem(rename)
            }
            addHideItem(to: menu, action: #selector(hideSection(_:)), representedObject: section.id)
        }

        let hidden = preferences.hiddenSidebarSections
        let restore = NSMenu()
        for kind in SidebarSection.Kind.allCases where hidden.contains(kind.rawValue) {
            let item = NSMenuItem(title: kind.title, action: #selector(showSection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            restore.addItem(item)
        }
        for group in preferences.sidebarGroups {
            let id = SidebarSection.id(forGroup: group.id)
            guard hidden.contains(id) else { continue }
            let item = NSMenuItem(title: group.name, action: #selector(showSection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            restore.addItem(item)
        }
        if preferences.sidebarHidesRecents && !hidden.contains(SidebarSection.Kind.favorites.rawValue) {
            let item = NSMenuItem(title: SidebarItem.recentsTitle, action: #selector(showRecents(_:)), keyEquivalent: "")
            item.target = self
            restore.addItem(item)
        }
        guard !restore.items.isEmpty else { return }
        let show = NSMenuItem(title: String(localized: "Show in Sidebar"), action: nil, keyEquivalent: "")
        show.submenu = restore
        menu.addItem(show)
    }

    @objc private func hideSection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preferences.hiddenSidebarSections.insert(id)
    }

    @objc private func showSection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        preferences.hiddenSidebarSections.remove(id)
    }

    @objc private func hideRecents(_ sender: NSMenuItem) { preferences.sidebarHidesRecents = true }

    @objc private func showRecents(_ sender: NSMenuItem) { preferences.sidebarHidesRecents = false }

    @objc private func openSMB(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelect?(.smb(id))
    }

    @objc private func manageSMB(_ sender: NSMenuItem) { services.showSetting(.smbConnections) }

    /// Disconnect (while connected), edit, copy its address, remove.
    private func addServerItems(_ server: RemoteServer, to menu: NSMenu) {
        func entry(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = server.id
            menu.addItem(item)
        }
        if services.remote.status.connected.contains(server.id) {
            entry(String(localized: "Disconnect", comment: "Button: end the connection to the server"), #selector(disconnectServer(_:)))
            menu.addItem(.separator())
        }
        entry(String(localized: "Edit…", comment: "Sidebar menu: change a saved server's settings"), #selector(editServer(_:)))
        entry(String(localized: "Copy Address", comment: "Sidebar menu: copy a server's address"), #selector(copyServerAddress(_:)))
        menu.addItem(.separator())
        entry(String(localized: "Remove “\(server.name)”…", comment: "Sidebar menu: forget a saved server"), #selector(removeServer(_:)))
    }

    private var windowController: BrowserWindowController? { view.window?.windowController as? BrowserWindowController }

    @objc private func disconnectServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        windowController?.disconnectServer(server)
    }

    @objc private func editServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        windowController?.editServer(server)
    }

    @objc private func copyServerAddress(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id) else { return }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(server.address, forType: .string)
    }

    @objc private func removeServer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let server = services.remote.servers.server(id: id), let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(server.name)” from Strata?", comment: "A saved server's name")
        alert.informativeText = server.kind == .s3
            ? String(localized: "Its secret key is deleted from your keychain. Nothing in the bucket changes.")
            : String(localized: "Nothing on the server changes.")
        alert.addButton(withTitle: String(localized: "Remove", comment: "Alert button: forget the saved server"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [remote = services.remote] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { _ = remote.remove(server) }
        }
    }

    /// Open, save this window into it (only the window it belongs to), rename or delete.
    private func addWorkspaceItems(_ name: String, to menu: NSMenu) {
        func entry(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        entry(String(localized: "Open", comment: "Sidebar menu: open the saved workspace"), #selector(openWorkspace(_:)))
        menu.addItem(.separator())
        if (view.window?.windowController as? BrowserWindowController)?.groupWorkspaceName == name {
            entry(String(localized: "Update with This Window", comment: "Sidebar menu: save this window's tabs and panes into the workspace"),
                  #selector(updateWorkspace(_:)))
        }
        entry(String(localized: "Rename…"), #selector(renameWorkspace(_:)))
        menu.addItem(.separator())
        entry(String(localized: "Delete Workspace"), #selector(deleteWorkspace(_:)))
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let workspace = services.workspaces.named(name) else { return }
        services.workspaces.open(workspace, from: view.window)
    }

    @objc private func updateWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let window = view.window else { return }
        services.workspaces.update(name, from: window)
    }

    @objc private func renameWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.workspaces.askToRename(name, in: view.window)
    }

    @objc private func deleteWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.workspaces.confirmDelete(name, in: view.window)
    }

    private func add(_ title: String.LocalizationValue, _ action: Selector, _ url: URL) {
        let entry = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
        entry.target = self
        entry.representedObject = url
        outline.menu?.addItem(entry)
    }

    @objc private func forgetTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        services.tags.forget(name)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onOpenInNewTab?(url)
    }

    @objc private func copyItemPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.clipboard.pasteboard.clearContents()
        services.clipboard.pasteboard.setString(url.path, forType: .string)
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.removeFavorite(url, preferences: preferences, checks: services.places)
    }

    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        addFavorites([url], at: nil)
    }

    @objc func removeFrequent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        services.visits.forget(url)
        reload()
    }

    @objc private func ejectItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Places.eject(url, from: view.window)
    }
}

/// Saved SMB rows in both sidebar modes use the same commands.
func addSMBMenu(to menu: NSMenu, id: UUID, connect: Selector, manage: Selector, target: AnyObject) {
    let open = NSMenuItem(title: String(localized: "Connect", comment: "Button: connect to the server"), action: connect, keyEquivalent: "")
    open.target = target
    open.representedObject = id
    menu.addItem(open)
    let settings = NSMenuItem(title: String(localized: "SMB Connections…"), action: manage, keyEquivalent: "")
    settings.target = target
    menu.addItem(settings)
}
