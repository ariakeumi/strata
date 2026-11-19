import AppKit

/// Search results, recent files and messages shown in place of the folder.
extension BrowserViewController {
    /// Shows `entries` (search results or recent files) in place of the folder, keeping their order until a column
    /// header is clicked. `total` is how many matched before the list was capped.
    func showResults(_ entries: [FileEntry], total: Int) {
        // When a refreshed search finds the same files, the list, its selection
        // and the Inspector stay as they are, and only rows whose size or date moved are redrawn.
        if isShowingResults, pending.selection == nil, results.total != nil, loadError == nil, updateResultsInPlace(entries) {
            if results.total != total {
                results.total = total
                delegate?.browserContentDidChange(self)
            }
            return
        }
        // Read before switching to the list: in other views the list's own selection is stale and could point at a file
        // nobody picked.
        let selection = pending.selection ?? presentationSelection.map(\.url)
        enterResults()
        loading.showResults()
        sizer.cancelPending()
        mediaInfo.cancelPending()
        results.total = total
        listing.replace(entries, preservingNodes: false, sort: sort)
        outlineView.reloadData()
        pushContent()
        select(selection, scroll: false)
        pending.selection = nil
        updateEmptyState()
        delegate?.browserContentDidChange(self)
        delegate?.browserSelectionDidChange(self)
    }

    /// When `entries` are the files already listed (in any order: a clicked column header sorts them), takes their new
    /// sizes and dates and returns true. Otherwise changes nothing and returns false.
    private func updateResultsInPlace(_ entries: [FileEntry]) -> Bool {
        guard let changed = listing.updateResults(entries, sorted: ordering.choice != nil) else { return false }
        guard !changed.isEmpty else { return true }
        var rowsToReload = IndexSet()
        for node in changed {
            let row = outlineView.row(forItem: node)
            if row >= 0 { rowsToReload.insert(row) }
        }
        outlineView.reloadData(forRowIndexes: inlineRename.except(rowsToReload, in: outlineView), columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
        pushContent()
        delegate?.browserContentDidChange(self)
        if changed.contains(where: { outlineView.selectedRowIndexes.contains(outlineView.row(forItem: $0)) }) {
            delegate?.browserSelectionDidChange(self)
        }
        return true
    }

    /// Replaces the list with a message while results are being computed, or in place of results there can't be.
    func showMessage(symbol: String, title: String, message: String = "", button: (String, () -> Void)? = nil) {
        noteNavigationContextChanged()
        activeView?.cancelRename()
        enterResults()
        loading.showResults(loaded: false, forgetDirectory: smbShares != nil)
        sizer.cancelPending()
        mediaInfo.cancelPending()
        listing.clear()
        results.total = nil
        outlineView.reloadData()
        pushContent()
        emptyState.show(symbol: symbol, title: title, message: message, button: button)
        delegate?.browserContentDidChange(self)
    }

    private func enterResults() {
        if !isShowingResults {
            cancelPendingActions()
            inlineRename.dropHeldListing()
            results.enter(iconSize: iconSize)
            ordering.enterResults()
            folderOptions?.refresh()
            installActiveView()
            syncSortDescriptor()
            if smbShares == nil { results.makeRoomForWhere(in: outlineView) }
            fitNameColumn()
            clearFilter()
        }
    }

    func leaveResults() {
        ordering.leaveResults()
        if let size = results.leave() { setIconSize(size, remember: false) }
        if folderSettingsChangedInResults, let directory {
            folderSettingsChangedInResults = false
            restoreFolderPresentation(at: directory, showing: false)
        }
        folderOptions?.refresh()
        installActiveView()
        results.restoreColumns(in: outlineView)
        fitNameColumn()
        syncSortDescriptor()
    }

    func showSMBShareList(at root: URL?, reload: @escaping () -> Void) -> SMBSharePage {
        let previous = smbShares
        if previous == nil && isShowingResults {
            leaveResults()
        }
        let shares = SMBSharePage(root: root, mode: previous?.mode ?? mode, onReload: reload)
        let selection = previous != nil && previous?.root == root ? presentationSelection.map(\.url) : []
        let choice = previous == nil ? BrowserOrdering.Choice(key: .name, ascending: true) : ordering.choice
        smbShares = shares
        watching.stop()
        clearFilter()
        showMessage(symbol: "network", title: String(localized: "Loading…"))
        pending.selection = selection
        if let choice { ordering.choose(choice) }
        syncSortDescriptor()
        installActiveView()
        return shares
    }

    func publishSMBShares(_ names: [String], open: @escaping (String) -> Void) {
        guard let smbShares, let root = smbShares.root else { return }
        smbShares.onOpen = open
        let kind = FileEntry.kind(extension: "", isDirectory: true, isPackage: false, size: nil, system: nil, type: nil)
        let entries = names.map { name in
            FileEntry(url: root.appending(component: name, directoryHint: .notDirectory), name: name,
                      isDirectory: true, isPackage: false, isHidden: false, isSymlink: false, isVolume: false,
                      size: nil, modified: nil, created: nil, added: nil, kind: kind, contentType: nil)
        }
        showResults(entries, total: entries.count)
    }

    func leaveSMBShareList() {
        guard smbShares != nil else { return }
        listing.clear()
        outlineView.reloadData()
        pushContent()
        smbShares = nil
        leaveResults()
    }
}
