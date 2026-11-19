import AppKit
import StrataModel
import StrataTheme

extension BrowserWindowController {
    // MARK: - Search

    /// Starts a search from outside the window (the `strata` command, URL scheme).
    func search(_ query: String, in scope: URL?) {
        go(.search(query, scope: scope ?? currentSearchFolder))
    }

    var currentSearchFolder: URL {
        if case .search(_, let folder) = destination { return folder }
        if browser.mode == .columns, let column = pane.columnLocation { return column }
        return location
    }

    /// The toolbar searches recursively from the folder shown in the active pane.
    private func searchTextChanged(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            if case .search = destination { leaveSearch() }
            return
        }
        if case .search(_, let scope) = destination {
            destination = .search(query, scope: scope)
            if let title = ResultsTitle(destination) { window?.title = title.window }
            // Typing or deleting case: shows on the checkbox.
            split.scopeBar.setMatchCase(SearchQuery.isCaseSensitive(query), applies: Self.caseApplies(query))
            updateHeaders()
            pane.search.run(debounce: true)
        } else {
            search(query, in: nil)
        }
    }

    /// Clearing the field returns to the folder the search started from.
    func leaveSearch() {
        if case .folder = pane.history.back.last {
            go(pane.history.back.removeLast(), recordHistory: false)
        } else {
            go(.folder(location), recordHistory: false)
        }
    }

    /// Whether Match Case means anything for `text`: not for Spotlight's searches or plain-English readings.
    static func caseApplies(_ text: String) -> Bool {
        SpotlightQuery.parse(text) == nil && NaturalQuery.interpret(text) == nil
    }

    /// Match Case: the same search with `case:` added or taken out (so a saved search keeps it).
    func setSearchCase(_ on: Bool) {
        guard case .search(let text, let scope) = destination else { return }
        let updated = SearchQuery.settingCase(on, in: text)
        guard updated != text, !updated.isEmpty else { return }
        destination = .search(updated, scope: scope)
        updateChrome()
        pane.search.run()
    }

    func saveSearch() {
        guard case .search(let text, let scope) = destination else { return }
        let saved = SavedSearch(name: text, query: text, scopePath: scope.path)
        guard services.savedSearches.save(saved) else { return }
        split.sidebar.highlight(.search(saved))
    }
}

extension BrowserWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        searchTextChanged(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        if case .search = destination { leaveSearch() } else { browser.setFilter("") }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            focusList()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            focusList()
            browser.openSelection(nil)
            return true
        default:
            return false
        }
    }
}

extension BrowserWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        browser.selectedURLs
    }
}
