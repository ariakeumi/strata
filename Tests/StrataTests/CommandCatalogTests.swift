import AppKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

@Suite(.serialized)
struct CommandCatalogTests {
    let testEnvironment: IndependentEnvironment

    init() throws { testEnvironment = try IndependentEnvironment() }

    private func waitForLoad(_ browser: BrowserViewController) async throws {
        for _ in 0..<200 {
            if browser.isLoaded && !browser.isLoadingFolder { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(browser.isLoaded && !browser.isLoadingFolder)
    }

    private func window(at folder: URL, other: URL? = nil) throws -> BrowserWindowController {
        let _ = NSApplication.shared
        let controller = BrowserWindowController(location: folder, secondPane: other, services: testEnvironment.services)
        controller.split.splitView.autosaveName = nil
        let window = try #require(controller.window)
        window.setFrameAutosaveName("")
        return controller
    }

    private func offered(_ command: StrataCommand, by controller: BrowserWindowController) -> Bool {
        controller.commandItems().contains { $0.commandID == command.id }
    }

    @Test func paletteAndContextMenuUseNativeAvailabilityInEveryViewAndBothPanes() async throws {
        let tree = try TestTree("left/", "left/a.zip", "right/", "right/b.zip")
        let controller = try window(at: tree.url("left"), other: tree.url("right"))
        defer { controller.window?.contentViewController = nil }
        let first = controller.browser
        let second = try #require(controller.otherBrowser)
        try await waitForLoad(first)
        try await waitForLoad(second)
        for (browser, selected) in [(first, tree.url("left/a.zip")), (second, tree.url("right/b.zip"))] {
            for mode in BrowserViewMode.ordered {
                browser.setMode(mode, remember: false)
                controller.window?.makeFirstResponder(browser.focusView)
                try #require(controller.browser === browser)
                browser.select([selected])
                try #require(browser.selectedURLs == [selected])
                let context = browser.contextMenu()
                for command in [StrataCommand.duplicate, .renameSelection, .newFolder, .compress, .extract, .share, .moveToTrash] {
                    let native = command.menuItem()
                    let available = browser.validateMenuItem(native)
                    #expect(offered(command, by: controller) == available, "\(command.id) in \(mode)")
                    if let item = context.items.first(where: { $0.action == command.action }) {
                        #expect(item.identifier?.rawValue == command.id)
                        #expect(browser.validateMenuItem(item) == available)
                    }
                }
                #expect(offered(.renameSelection, by: controller) == (mode != .treemap))
                #expect(offered(.newFolder, by: controller) == (mode != .treemap))
                #expect(offered(.duplicate, by: controller))
            }
        }
        #expect(controller.window?.isVisible == false)
        #expect(tree.snapshot() == ["left/", "left/a.zip", "right/", "right/b.zip"])
    }

    @Test func commandsCapturedBeforeResultsOrNavigationRevalidateBeforeChangingFiles() async throws {
        let tree = try TestTree("a.zip", "next/", "next/b.zip")
        let controller = try window(at: tree.root)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        let newFolder = try #require(controller.paletteCommand(.newFolder))
        let newFile = try #require(controller.paletteCommand(.newFile))
        controller.browser.showResults([try #require(FileEntry(url: tree.url("a.zip")))], total: 1)
        #expect(!offered(.newFolder, by: controller))
        #expect(!offered(.newFile, by: controller))
        newFolder.run()
        newFile.run()
        #expect(tree.snapshot() == ["a.zip", "next/", "next/b.zip"])
        controller.navigate(to: tree.url("next"))
        try #require(controller.browser.isLoadingFolder)
        #expect(!offered(.newFolder, by: controller))
        newFolder.run()
        newFile.run()
        try await waitForLoad(controller.browser)
        #expect(offered(.newFolder, by: controller))
        newFolder.run()
        newFile.run()
        #expect(controller.window?.isVisible == false)
        #expect(tree.snapshot() == ["a.zip", "next/", "next/b.zip"])
    }

    @Test func aCapturedCommandRechecksAvailabilityWithoutASelectionOrLocationChange() async throws {
        let tree = try TestTree("a.zip", "b.zip")
        let controller = try window(at: tree.root)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        controller.browser.select([])
        let command = try #require(controller.paletteCommand(.newFolder))
        controller.browser.setMode(.treemap, remember: false)
        try #require(controller.browser.selectedURLs.isEmpty)
        command.run()
        #expect(tree.snapshot() == ["a.zip", "b.zip"])
    }

    @Test func trashDoesNotOfferDuplicateAndKeepsPutBackTitle() async throws {
        let volume = try await ScratchVolume.make()
        do {
            let trash = volume.url(".Trashes/\(getuid())")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let file = trash.appending(path: "a.txt")
            try Data("chosen".utf8).write(to: file)
            let controller = try window(at: trash)
            defer { controller.window?.contentViewController = nil }
            try await waitForLoad(controller.browser)
            controller.browser.setMode(.list, remember: false)
            controller.browser.select([file])
            try #require(controller.browser.isShowingTrash)
            try #require(controller.browser.selectedURLs.map(\.standardizedFileURL) == [file.standardizedFileURL])
            #expect(!offered(.duplicate, by: controller))
            #expect(!offered(.newFolder, by: controller))
            #expect(!controller.browser.validateMenuItem(StrataCommand.duplicate.menuItem()))
            let putBack = try #require(controller.paletteCommand(.moveToTrash))
            #expect(putBack.title == String(localized: "Put Back"))
            #expect(putBack.commandID == StrataCommand.moveToTrash.id)
            #expect(TestTree.listing(of: trash) == ["a.txt"])
            #expect(try Data(contentsOf: file) == Data("chosen".utf8))
        } catch {
            await volume.eject()
            throw error
        }
        await volume.eject()
    }

    @Test func archiveAvailabilityDoesNotDependOnDisplayText() async throws {
        let top = ArchiveCache.root.appending(path: "commands-\(UUID().uuidString)")
        let folder = top.appending(path: "contents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: top) }
        let file = folder.appending(path: "a.txt")
        try Data("archive".utf8).write(to: file)
        let controller = try window(at: folder)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        controller.browser.select([file])
        try #require(controller.browser.isInsideArchive)
        try #require(controller.browser.selectedURLs.map(\.standardizedFileURL) == [file.standardizedFileURL])
        #expect(controller.paletteCommand(.askStrata) == nil)
        for command in [StrataCommand.duplicate, .newFolder, .newFile, .renameSelection, .moveToTrash, .deleteImmediately, .editTags] {
            #expect(controller.paletteCommand(command, title: "Unrelated translated display text") == nil)
            #expect(!offered(command, by: controller))
        }
        let copy = try #require(controller.paletteCommand(.copyPath, title: "Same title as another command"))
        #expect(copy.commandID == StrataCommand.copyPath.id)
        #expect(copy.title == "Same title as another command")
        #expect(TestTree.listing(of: top) == ["contents/", "contents/a.txt"])
    }

    @Test func nativeDispatchStillRunsTheSelectedCommand() async throws {
        let tree = try TestTree("a.zip", "b.zip")
        let controller = try window(at: tree.root)
        defer { controller.window?.contentViewController = nil }
        try await waitForLoad(controller.browser)
        controller.browser.setMode(.list, remember: false)
        controller.browser.select([tree.url("a.zip")])
        let rename = try #require(controller.paletteCommand(.renameSelection, title: "A different title"))
        rename.run()
        let outline = controller.browser.outlineView
        let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        let cell = try #require(outline.view(atColumn: column, row: outline.selectedRow, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.isEditable == true)
        controller.window?.endEditing(for: nil)
        #expect(tree.snapshot() == ["a.zip", "b.zip"])
    }

    @Test(arguments: [false, true])
    func enterOpensAndCommandEnterStartsRename(keypad: Bool) async throws {
        let tree = try TestTree("folder/selected/", "folder/sibling/")
        let controller = try window(at: tree.root)
        let window = try #require(controller.window)
        defer { window.contentViewController = nil }
        let browser = controller.browser
        try await waitForLoad(browser)
        browser.setMode(.list, remember: false)
        window.makeFirstResponder(browser.outlineView)
        browser.select([tree.url("folder")])

        let keyCode = keypad ? KeyCode.numpadEnter : KeyCode.returnKey
        let characters = keypad ? "\u{3}" : "\r"
        let flags: NSEvent.ModifierFlags = keypad ? .numericPad : []
        func event(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(modifiers),
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: keyCode))
        }
        browser.outlineView.keyDown(with: try event([]))
        try await waitForLoad(browser)
        try #require(browser.directory?.lexicallyStandardized.fileViewKey == tree.url("folder").lexicallyStandardized.fileViewKey)
        let selected = tree.url("folder/selected")
        browser.select([selected])

        let menu = NSMenu()
        let command = keypad ? StrataCommand.renameSelectionKeypad : .renameSelection
        menu.addItem(command.menuItem(target: browser))
        #expect(try menu.performKeyEquivalent(with: event(.command)))
        #expect(browser.inlineRename.isEditing)
        #expect(browser.selectedURLs.map { $0.lexicallyStandardized.fileViewKey } == [selected.lexicallyStandardized.fileViewKey])
        window.endEditing(for: nil)
        #expect(tree.snapshot() == ["folder/", "folder/selected/", "folder/sibling/"])
    }

    @Test func copyPathShortcutCopiesSelectedOrCurrentFolder() async throws {
        let tree = try TestTree("folder/")
        let controller = try window(at: tree.root)
        defer { controller.window?.contentViewController = nil }
        let browser = controller.browser
        try await waitForLoad(browser)
        browser.setMode(.list, remember: false)

        let menu = NSMenu()
        menu.addItem(StrataCommand.copyPath.menuItem(target: browser))
        let source = try #require(CGEventSource(stateID: .privateState))
        let cKey: CGKeyCode = 8
        let key = try #require(CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true))
        key.flags = [.maskCommand, .maskShift]
        let event = try #require(NSEvent(cgEvent: key))
        let pasteboard = testEnvironment.services.clipboard.pasteboard
        browser.select([tree.url("folder")])
        #expect(menu.performKeyEquivalent(with: event))
        #expect(pasteboard.string(forType: .string) == tree.url("folder").path)

        browser.select([])
        #expect(menu.performKeyEquivalent(with: event))
        #expect(pasteboard.string(forType: .string) == tree.root.lexicallyStandardized.path)
        #expect(tree.snapshot() == ["folder/"])
    }

    @Test func dockMenusAndDockSearchUseTheSameNativeCommandIdentities() {
        let _ = NSApplication.shared
        let dock = DockMenu(favorites: { [] }, newWindow: {}, recents: {}, openFolder: { _ in })
        let menu = dock.build()
        let definitions: [StrataCommand] = [.newWindow, .goRecents]
        for (item, command) in zip(menu.items, definitions) {
            #expect(item.identifier?.rawValue == command.id)
            #expect(item.title == command.title)
        }
        let commands = DockSearchItems.commands()
        for command in [StrataCommand.newWindow, .goRecents, .showSettings, .toggleShelf, .emptyTrash, .connectToServer, .showShortcuts] {
            let item = commands.first { $0.commandID == command.id }
            #expect(item?.title == command.title)
            #expect(item?.shortcut == command.shortcut)
        }
        #expect(Set(commands.compactMap(\.commandID)).count == commands.count)
        #expect(dock.build().items.count == 2)
    }

    @Test func numberShortcutsFollowShownSidebarFoldersAndNavigateTheActivePane() async throws {
        let tree = try TestTree("left/", "right/", "first/", "second/", "group/")
        let preferences = testEnvironment.preferences
        let favorites = SidebarSection.Kind.favorites.rawValue
        var group = Prefs.SidebarGroup(name: "Group")
        group.folderPaths = [tree.url("group").path]
        let groupID = SidebarSection.id(forGroup: group.id)
        preferences.favoritePaths = [tree.url("first").path, tree.url("second").path]
        preferences.sidebarGroups = [group]
        preferences.hiddenSidebarSections = Set(SidebarSection.Kind.allCases.map(\.rawValue)).subtracting([favorites])
        let controller = try window(at: tree.url("left"), other: tree.url("right"))
        let window = try #require(controller.window)
        defer { window.contentViewController = nil }
        let left = try #require(controller.panes.first)
        let right = try #require(controller.panes.last)
        controller.activate(right)
        try await waitForLoad(right.browser)
        right.browser.setMode(.list, remember: false)

        let menu = NSMenu()
        for command in StrataCommand.sidebarFolders { menu.addItem(command.menuItem(target: controller)) }
        menu.addItem(StrataCommand.view(.grid).menuItem(target: controller))
        func pressOne(_ modifiers: NSEvent.ModifierFlags) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "1",
                charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
            return menu.performKeyEquivalent(with: event)
        }

        let sidebar = controller.split.sidebar
        func path(_ folder: String) -> String { tree.url(folder).lexicallyStandardized.path }
        #expect(sidebar.folder(at: 2)?.path == path("second"))
        #expect(sidebar.folder(at: 3)?.path == path("group"))
        #expect(!controller.validateMenuItem(menu.items[3]))
        #expect(try pressOne([.control, .command]))
        #expect(right.browser.mode == .grid)
        #expect(right.location.lexicallyStandardized.path == path("right"))
        #expect(try pressOne(.command))
        #expect(right.location.lexicallyStandardized.path == path("first"))

        preferences.sidebarSectionOrder = [groupID, favorites]
        #expect(try pressOne(.command))
        #expect(right.location.lexicallyStandardized.path == path("group"))
        let groupSection = try #require(sidebar.sections.first { $0.id == groupID })
        sidebar.outline.collapseItem(groupSection)
        #expect(try pressOne(.command))
        #expect(right.location.lexicallyStandardized.path == path("first"))
        #expect(left.location.lexicallyStandardized.path == path("left"))

        preferences.sidebarShowsTree = true
        #expect(sidebar.folder(at: 1)?.fileViewKey == Places.home.fileViewKey)
        #expect(tree.snapshot() == ["first/", "group/", "left/", "right/", "second/"])
    }

    @Test func shortcutOverridesAndAlternatesKeepTheirExistingIdentities() throws {
        let app = NSApplication.shared
        let saved = (app.windowsMenu, app.helpMenu, app.servicesMenu)
        let preferences = try Prefs.isolated().defaults
        defer {
            app.windowsMenu = saved.0
            app.helpMenu = saved.1
            app.servicesMenu = saved.2
        }
        let menu = MainMenu.build()
        let fileActions = [StrataCommand.copy.action, StrataCommand.newFolder.action, StrataCommand.moveToTrash.action]
        let fileCommands = menu.items.flatMap { $0.submenu?.items ?? [] }
            .filter { item in item.action.map { fileActions.contains($0) } == true }
        #expect(fileCommands.count == 3)
        #expect(fileCommands.allSatisfy { $0.target == nil })
        let shortcuts = ShortcutStore(preferences: preferences)
        shortcuts.install(menu)
        let ids = shortcuts.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("go.openSelection"))
        #expect(ids.contains("go.editLocation"))
        for mode in BrowserViewMode.ordered {
            let command = StrataCommand.view(mode)
            #expect(ids.contains(command.id))
            #expect(shortcuts.combo(for: command.id).display == "⌃⌘\(mode.position + 1)")
        }
        for (index, command) in StrataCommand.sidebarFolders.enumerated() {
            #expect(shortcuts.combo(for: command.id).display == "⌘\(index + 1)")
        }
        #expect(StrataCommand.sidebarFolders.count == 9)
        #expect(shortcuts.combo(for: "duplicate:").display == "⌘D")
        #expect(shortcuts.combo(for: "go.editLocation").display == "⌘L")
        let rename = StrataCommand.renameSelection
        let keypad = StrataCommand.renameSelectionKeypad
        #expect(shortcuts.combo(for: rename.id).display == "⌘↩")
        #expect(!ids.contains(keypad.id))
        #expect(shortcuts.display(for: keypad.id, fallback: .cleared) == "⌘↩")
        shortcuts.set(.cleared, for: rename.id)
        #expect(shortcuts.display(for: keypad.id, fallback: .cleared).isEmpty)
        shortcuts.reset(rename.id)
        #expect(shortcuts.display(for: keypad.id, fallback: .cleared) == "⌘↩")
        let reassigned = ShortcutStore.Combo(key: "\r", modifiers: NSEvent.ModifierFlags.command.rawValue)
        shortcuts.overrides = [StrataCommand.copy.id: reassigned]
        shortcuts.install(menu)
        #expect(shortcuts.combo(for: StrataCommand.copy.id) == reassigned)
        #expect(shortcuts.combo(for: rename.id) == .cleared)
        #expect(shortcuts.display(for: keypad.id, fallback: .cleared).isEmpty)
        shortcuts.overrides = ["moveToTrash:": .init(key: "d", modifiers: NSEvent.ModifierFlags.control.rawValue)]
        #expect(shortcuts.display(for: "moveToTrash:", fallback: .cleared) == "⌃D")
        #expect(shortcuts.display(for: "deleteImmediately:", fallback: .cleared) == "⌃⌥D")
        shortcuts.overrides = ["biggerIcons:": .init(key: "b", modifiers: NSEvent.ModifierFlags.command.rawValue)]
        #expect(shortcuts.display(for: "biggerIcons:", fallback: .cleared) == "⌘B")
        #expect(shortcuts.display(for: "biggerIcons:~1", fallback: .cleared) == "")
        // A second install must preserve the original defaults and the user's choices.
        shortcuts.install(menu)
        #expect(shortcuts.combo(for: "biggerIcons:").display == "⌘B")
        #expect(shortcuts.display(for: "biggerIcons:~1", fallback: .cleared) == "")
    }
}
