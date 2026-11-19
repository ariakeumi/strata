import AppKit

extension SidebarViewController {
    func orderedSectionIDs(customIDs: [String]) -> [String] {
        let known = SidebarSection.Kind.allCases.map(\.rawValue) + customIDs
        var remaining = Set(known)
        return (preferences.sidebarSectionOrder + known).filter { remaining.remove($0) != nil }
    }

    func sectionDropIndex(_ info: NSDraggingInfo, proposedItem item: Any?, childIndex index: Int) -> Int? {
        guard let item else { return index == NSOutlineViewDropOnItemIndex ? sections.count : index }
        let header = (item as? SidebarSection) ?? (outline.parent(forItem: item) as? SidebarSection)
        guard let header, let section = sections.firstIndex(where: { $0 === header }) else { return nil }
        let row = outline.row(forItem: header)
        guard row >= 0 else { return nil }
        let point = outline.convert(info.draggingLocation, from: nil)
        return section + (point.y < outline.rect(ofRow: row).midY ? 0 : 1)
    }

    func sectionMove(for info: NSDraggingInfo, at index: Int) -> (id: String, anchor: String, after: Bool)? {
        guard info.draggingSource as? NSOutlineView === outline,
              info.draggingSourceOperationMask.contains(.move),
              let id = info.draggingPasteboard.string(forType: .sidebarSection),
              let from = sections.firstIndex(where: { $0.id == id }),
              (0...sections.count).contains(index), index != from, index != from + 1 else { return nil }
        // Anchor to a visible neighbor so hidden sections keep their order.
        let atEnd = index == sections.count
        return (id, sections[atEnd ? index - 1 : index].id, atEnd)
    }

    func moveSection(for info: NSDraggingInfo, at index: Int) -> Bool {
        guard let move = sectionMove(for: info, at: index) else { return false }
        var order = orderedSectionIDs(customIDs: preferences.sidebarGroups.map { SidebarSection.id(forGroup: $0.id) })
        guard let source = order.firstIndex(of: move.id) else { return false }
        order.remove(at: source)
        guard let position = order.firstIndex(of: move.anchor) else { return false }
        order.insert(move.id, at: position + (move.after ? 1 : 0))
        preferences.sidebarSectionOrder = order
        return true
    }

    func customSections() -> [SidebarSection] {
        preferences.sidebarGroups.map { group in
            let items = group.folderPaths.map { path in
                let url = URL(filePath: path, directoryHint: .isDirectory)
                return SidebarItem(Place(title: services.places.name(url), url: url, symbol: Places.pinnedFolderSymbol(for: url)), groupID: group.id)
            }
            return SidebarSection(group: group, items: items)
        }
    }

    @objc func newSidebarGroup(_ sender: NSMenuItem) {
        askGroupName()
    }

    @objc func renameSidebarGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let group = preferences.sidebarGroups.first(where: { $0.id == id }) else { return }
        askGroupName(group)
    }

    private func askGroupName(_ group: Prefs.SidebarGroup? = nil) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = group == nil ? String(localized: "New Group") : String(localized: "Rename Group")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Name")
        field.setAccessibilityLabel(field.placeholderString)
        field.stringValue = group?.name ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: group == nil ? String(localized: "Save") : String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                self?.saveGroupName(field.stringValue, for: group?.id)
            }
        }
    }

    func saveGroupName(_ name: String, for id: UUID? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var groups = preferences.sidebarGroups
        if let id {
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
            groups[index].name = name
        } else {
            groups.append(Prefs.SidebarGroup(name: name))
        }
        preferences.sidebarGroups = groups
    }

    @objc func removeGroupFolder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? SidebarItem, let id = item.groupID, let path = item.url?.path else { return }
        var groups = preferences.sidebarGroups
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].folderPaths.removeAll { $0 == path }
        preferences.sidebarGroups = groups
    }

    func groupID(forDropOn item: Any?) -> UUID? {
        (item as? SidebarSection)?.groupID ?? (item as? SidebarItem)?.groupID
    }

    func addGroupFolders(_ urls: [URL], to id: UUID) {
        Task { [weak self] in
            let folders = await Places.folders(among: urls.map(\.lexicallyStandardized))
            guard let self, !folders.isEmpty else { return }
            var groups = preferences.sidebarGroups
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
            var saved = Set(groups[index].folderPaths)
            groups[index].folderPaths += folders.map(\.path).filter { saved.insert($0).inserted }
            preferences.sidebarGroups = groups
        }
    }
}
