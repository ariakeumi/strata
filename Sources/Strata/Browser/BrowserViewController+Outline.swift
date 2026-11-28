import AppKit
import StrataModel
import StrataTheme

// MARK: - Data source and delegate

extension BrowserViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else { return rows.count }
        guard let children = node.children else {
            loadChildren(of: node)
            return 0
        }
        return children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? FileNode else {
            if rows.indices.contains(index) { return rows[index] }
            if let first = rows.first { return first }
            return FileNode(entry: FileEntry(url: URL(fileURLWithPath: "/"), name: "", isDirectory: true, isPackage: false,
                                             isHidden: false, isSymlink: false, isVolume: false, size: nil, modified: nil, created: nil,
                                             added: nil, kind: "", contentType: nil))
        }
        guard let children = node.children, children.indices.contains(index) else { return node }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // A drag resting on a folder springs it open; the outline's own expand-on-hover would compete.
        !self.outlineView.isReceivingDrag
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        guard filter.isEmpty, !isShowingResults else { return false }
        return node.entry.isFolder
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ThemeRowView(alternatingRows: preferences.alternatingRows)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        guard let column = tableColumn else { return nil }
        let entry = node.entry
        let dimmed = entry.isHidden || services.clipboard.isCut(entry.url)
        if column.identifier == .name {
            let cell = outlineView.makeView(withIdentifier: .nameCell, owner: nil) as? NameCellView ?? {
                let cell = NameCellView()
                cell.identifier = .nameCell
                return cell
            }()
            cell.configure(name: entry.listName(showingExtension: preferences.showListNameExtensions), icon: services.thumbnails.icon(for: entry), matches: node.matchIndices, dimmed: dimmed,
                           tags: services.tags.tags(for: entry.url),
                           cloud: services.cloud.status(for: entry.url), thumbnail: preferences.showIconPreviews ? entry : nil,
                           thumbnails: services.thumbnails, scale: outlineView.window?.backingScaleFactor ?? 2,
                           typography: listTypography)
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .textCell, owner: nil) as? TextCellView ?? {
            let cell = TextCellView()
            cell.identifier = .textCell
            return cell
        }()
        switch column.identifier {
        case .modified: cell.configure(Format.date(entry.modified), alignment: .left, dimmed: dimmed)
        case .created: cell.configure(Format.date(entry.created), alignment: .left, dimmed: dimmed)
        case .added: cell.configure(Format.date(entry.added), alignment: .left, dimmed: dimmed)
        case .fileExtension: cell.configure(entry.url.pathExtension, alignment: .left, dimmed: dimmed)
        case .dimensions, .width, .height, .duration:
            mediaInfo.request(entry)
            let info = mediaInfo.cached(entry)
            let text: String?
            switch column.identifier {
            case .dimensions: text = info?.dimensions
            case .width: text = info?.width.map(String.init)
            case .height: text = info?.height.map(String.init)
            default: text = info?.durationText
            }
            cell.configure(text ?? (info == nil && mediaInfo.canRead(entry) ? "…" : "—"),
                           alignment: column.headerCell.alignment, dimmed: dimmed)
        case .tags: cell.configure(services.tags.tags(for: entry.url).map(\.name).joined(separator: ", "),
                                   alignment: .left, dimmed: dimmed)
        case .size: cell.configure(entry.isDirectory ? folderSizeText(entry) : Format.bytes(entry.size ?? 0), alignment: .right, dimmed: dimmed)
        case .location: cell.configure(Format.tildePath(entry.url.deletingLastPathComponent()), alignment: .left, dimmed: dimmed)
        default: cell.configure(entry.kind, alignment: .left, dimmed: dimmed)
        }
        return cell
    }

    func folderSizeText(_ entry: FileEntry) -> String {
        guard showsSize(entry) else { return "—" }
        let automatic = preferences.automaticFolderSizes
        if let size = folderSize(entry.url, request: automatic) {
            return Format.bytes(size.bytes)
        }
        return automatic ? "…" : "—"
    }

    /// Only walk local folders whose access is already available.
    func canMeasure(_ entry: FileEntry) -> Bool {
        guard entry.isDirectory, !entry.isSymlink, !entry.isVolume, !services.copies.contains(entry.url), let directory else { return false }
        return FolderSizer.cached(entry.url) != nil
            || (!Privacy.measuringWouldPrompt(entry.url, browsing: directory) && !Privacy.walkingWouldReachGuardedFolders(entry.url))
    }

    /// A folder whose badge says it is only in the cloud is left for an explicit measurement.
    func showsSize(_ entry: FileEntry) -> Bool {
        canMeasure(entry)
            && (services.cloud.status(for: entry.url)?.isPlaceholder != true || folderSize(entry.url) != nil)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !isApplyingListing, loading.hasPartialListing || filtering.matching != nil { pending.cancel() }
        delegate?.browserSelectionDidChange(self)
        prefetchSelection()
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        // The header follows the pane's choice (`syncSortDescriptor`): only a click that picks another order applies it.
        guard let descriptor = outlineView.sortDescriptors.first, let key = SortKey(rawValue: descriptor.key ?? ""),
              ordering.choice != .init(key: key, ascending: descriptor.ascending) else { return }
        applySort(key, ascending: descriptor.ascending)
    }

    func applySort(_ key: SortKey, ascending direction: Bool, remember: Bool = true) {
        if key == .tags, isShowingResults, smbShares == nil { services.tags.load(nodes.flatMap { $0.children ?? [$0] }.map(\.entry)) }
        ordering.choose(.init(key: key, ascending: direction), remember: remember)
        if !remember, directory == nil, !isShowingResults { initialSort = .init(key: key, ascending: direction) }
        syncSortDescriptor()
        if remember, !isShowingResults {
            if hasCustomFolderPresentation { rememberFolderPresentation() }
            else { preferences.sortColumn = key.rawValue; preferences.sortAscending = direction }
            folderOptions?.refresh()
        }
        let selection = presentationSelection.map(\.url)
        listing.sort(using: sort)
        outlineView.reloadData()
        pushContent()
        select(selection, scroll: false)
        if loading.hasPartialListing { refresh() }
    }
}

// MARK: - Rename editing

extension BrowserViewController: NSTextFieldDelegate {
    func applyHeldListing() -> Bool {
        defer { filtering.resumeDeferredMatch() }
        guard let held = inlineRename.takeHeldListing(generation: generation) else { return false }
        apply(held.entries, preservingState: held.preservingState, fromTop: held.fromTop, sortedBy: held.sortedBy,
              complete: held.complete, progressive: held.progressive)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let ended = inlineRename.end(field) else { return }
        let node = ended.node, newName = ended.name
        if !applyHeldListing() {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
            }
        }
        view.window?.makeFirstResponder(outlineView)
        resorting.editingEnded()
        guard !newName.isEmpty, newName != node.entry.name else { return }
        renameItem(node.url, to: newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let node = inlineRename.node {
            (control as? NSTextField)?.stringValue = node.entry.name
            view.window?.makeFirstResponder(outlineView)
            return true
        }
        return false
    }
}
