import Foundation

nonisolated enum SettingsPage: String, CaseIterable, Sendable {
    case general, search, terminal, appearance, shortcuts, connections, viewOptions

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .search: String(localized: "Search")
        case .terminal: String(localized: "Terminal")
        case .appearance: String(localized: "Appearance")
        case .shortcuts: String(localized: "Shortcuts")
        case .connections: String(localized: "Connections")
        case .viewOptions: String(localized: "View Options")
        }
    }
}

nonisolated enum SettingID: String, CaseIterable, Sendable {
    case language, hiddenFiles, foldersFirst, addressBars, reopenWindows, archives, returnKey, newWindowFolder
    case newFileExtension, verifyCopies, dockSearch, defaultFileBrowser, commandLine
    case fullDiskAccess, searchSyntax, terminalApp
    case appearance, density, textSize, alternatingRows, iconPreviews, shortcuts
    case smbConnections
    case folderView, folderSort, iconSize, itemInfo, folderInfo, listColumns, nameExtensions

    var requiresFolder: Bool { [.folderView, .folderSort, .iconSize].contains(self) }
}

nonisolated struct SettingEntry: Sendable {
    let id: SettingID
    let page: SettingsPage
    let title: String
    let keywords: [String]
}

enum SettingsCatalog {
    static let entries: [SettingEntry] = [
        entry(.language, .general, "Language", "language locale translation"),
        entry(.hiddenFiles, .general, "Show hidden files", "hidden files dotfiles invisible"),
        entry(.foldersFirst, .general, "Keep folders on top", "folders first sorting directories"),
        entry(.addressBars, .general, "Address bar in each pane", "dual pane address path bars"),
        entry(.reopenWindows, .general, "Reopen windows from last time", "restore reopen windows tabs session startup"),
        entry(.archives, .general, "Open archives like folders", "archives zip tar browse extract"),
        entry(.returnKey, .general, "Return key", "return enter rename open keyboard"),
        entry(.newWindowFolder, .general, "New windows open", "new windows folder home startup"),
        entry(.newFileExtension, .general, "Extension", "new file default extension txt markdown"),
        entry(.verifyCopies, .general, "Verify copies", "verify copies checksum integrity copying"),
        entry(.dockSearch, .general, "Search box in the Dock", "dock search accessibility"),
        entry(.defaultFileBrowser, .general, "Open “Reveal in Finder” in Strata", "default file browser reveal finder"),
        entry(.commandLine, .general, "Command Line", "cli shell command line install strata"),
        entry(.fullDiskAccess, .search, "Full Disk Access", "privacy permissions full disk access search"),
        entry(.searchSyntax, .search, "Search Syntax", "search syntax query filters extensions size date"),
        entry(.terminalApp, .terminal, "Open in Terminal uses", "terminal ghostty iterm warp default shell"),
        entry(.appearance, .appearance, "Appearance", "appearance dark light system"),
        entry(.density, .appearance, "Density", "row spacing density compact spacious"),
        entry(.textSize, .appearance, "Text size", "font text size typography"),
        entry(.alternatingRows, .appearance, "Alternating row colors", "zebra stripes alternating rows"),
        entry(.iconPreviews, .appearance, "Show icon previews", "thumbnails icons pictures previews"),
        entry(.shortcuts, .shortcuts, "Shortcuts", "keyboard shortcuts key bindings hotkeys"),
        entry(.smbConnections, .connections, "SMB Connections", "smb network server share mount password keychain nas connect at launch"),
        entry(.folderView, .viewOptions, "View", "folder view mode icons gallery columns use as defaults reset"),
        entry(.folderSort, .viewOptions, "Sort By", "folder sorting ascending descending reverse order"),
        entry(.iconSize, .viewOptions, "Icon size", "icons size zoom folder"),
        entry(.itemInfo, .viewOptions, "Show item info", "item information dimensions file size"),
        entry(.folderInfo, .viewOptions, "Folder info", "folder info item count total size"),
        entry(.listColumns, .viewOptions, "List columns", "list columns visibility metadata dimensions duration"),
        entry(.nameExtensions, .viewOptions, "Show extensions in Name column", "filename extensions hide show name column"),
    ]

    static func entry(for id: SettingID) -> SettingEntry? { entries.first { $0.id == id } }

    private static func entry(_ id: SettingID, _ page: SettingsPage, _ title: String.LocalizationValue, _ words: String) -> SettingEntry {
        let title = String(localized: title)
        return SettingEntry(id: id, page: page, title: title,
            keywords: [words, "settings " + words, "preferences " + words, page.title + " " + title, "settings " + title, "preferences " + title])
    }
}
