import AppKit
import Testing
@testable import Strata
@testable import StrataModel

struct SidebarSelectionTests {
    private func menu(in sidebar: SidebarViewController, at point: NSPoint) throws -> NSMenu {
        let outline = sidebar.outline
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: outline.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: outline.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
        let menu = try #require(outline.menu(for: event))
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    private func menu(in sidebar: SidebarViewController, for item: Any) throws -> NSMenu {
        let row = sidebar.outline.row(forItem: item)
        try #require(row >= 0)
        let rect = sidebar.outline.rect(ofRow: row)
        return try menu(in: sidebar, at: NSPoint(x: rect.midX, y: rect.midY))
    }

    @Test func draggingSectionHeadersReordersBuiltInAndCustomGroupsAcrossWindows() throws {
        let environment = try IndependentEnvironment(), independent = try IndependentEnvironment()
        defer { withExtendedLifetime((environment, independent)) {} }
        let preferences = environment.preferences
        let first = Prefs.SidebarGroup(name: "Projects"), second = Prefs.SidebarGroup(name: "Projects")
        preferences.sidebarGroups = [first, second]
        let sidebar = SidebarViewController(services: environment.services)
        let peer = SidebarViewController(services: environment.services)
        let isolated = SidebarViewController(services: independent.services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        sidebar.view.layoutSubtreeIfNeeded()
        _ = peer.view
        _ = isolated.view
        let outline = sidebar.outline
        let firstID = SidebarSection.id(forGroup: first.id), secondID = SidebarSection.id(forGroup: second.id)
        let initial = sidebar.sections.map(\.id)
        #expect(initial.suffix(2) == [firstID, secondID])
        let favorites = SidebarSection.Kind.favorites.rawValue
        let locations = SidebarSection.Kind.locations.rawValue
        preferences.collapsedSidebarSections.insert(secondID)
        preferences.hiddenSidebarSections.insert(locations)
        sidebar.reload()
        sidebar.highlight(.recents)
        var navigations = 0
        sidebar.onSelect = { _ in navigations += 1 }

        func drag(_ id: String, in source: SidebarViewController, location: NSPoint = .zero) throws -> FileDrag {
            let section = try #require(source.sections.first { $0.id == id })
            let writer = try #require(source.outlineView(source.outline, pasteboardWriterForItem: section))
            let drag = FileDrag([], offering: .move, source: source.outline, location: location)
            #expect(drag.draggingPasteboard.writeObjects([writer]))
            return drag
        }

        let fromPeer = try drag(secondID, in: peer)
        #expect(sidebar.outlineView(outline, validateDrop: fromPeer, proposedItem: nil, proposedChildIndex: 0) == [])
        #expect(!sidebar.outlineView(outline, acceptDrop: fromPeer, item: nil, childIndex: 0))

        let before = try #require(sidebar.sections.first)
        let rect = outline.rect(ofRow: outline.row(forItem: before))
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.minY + 2), to: nil)
        let group = try drag(secondID, in: sidebar, location: point)
        #expect(sidebar.outlineView(outline, validateDrop: group, proposedItem: nil, proposedChildIndex: outline.numberOfChildren(ofItem: nil)) == [])
        #expect(sidebar.outlineView(outline, validateDrop: group, proposedItem: nil, proposedChildIndex: 0) == .move)
        #expect(sidebar.outlineView(outline, validateDrop: group, proposedItem: before,
                                    proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        #expect(sidebar.outlineView(outline, acceptDrop: group, item: nil, childIndex: 0))
        #expect(sidebar.sections.first?.id == secondID && peer.sections.first?.id == secondID)
        #expect(!outline.isItemExpanded(sidebar.sections.first))
        #expect(sidebar.sections.last?.id == firstID)

        let builtin = try drag(favorites, in: sidebar)
        let end = sidebar.sections.count
        #expect(sidebar.outlineView(outline, validateDrop: builtin, proposedItem: nil, proposedChildIndex: end) == .move)
        #expect(sidebar.outlineView(outline, acceptDrop: builtin, item: nil, childIndex: end))
        preferences.hiddenSidebarSections.remove(locations)
        let expected = [secondID] + initial.filter { $0 != favorites && $0 != secondID } + [favorites]
        #expect(sidebar.sections.map(\.id) == expected && peer.sections.map(\.id) == expected)
        #expect((outline.item(atRow: outline.selectedRow) as? SidebarItem)?.target == .recents && navigations == 0)
        #expect(preferences.sidebarGroups == [first, second])
        #expect(independent.preferences.sidebarSectionOrder.isEmpty && isolated.sections.first?.id == favorites)
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: preferences.domainName)), domainName: preferences.domainName)
        #expect(reopened.sidebarSectionOrder.filter { expected.contains($0) } == expected)
    }

    @Test func blankSidebarMenuCreatesAPersistentGroupOfFolderShortcuts() async throws {
        let tree = try TestTree("folder/", "other/", "note.txt")
        let environment = try IndependentEnvironment(), independent = try IndependentEnvironment()
        let preferences = environment.preferences
        let sidebar = SidebarViewController(services: environment.services)
        let peer = SidebarViewController(services: environment.services)
        let isolated = SidebarViewController(services: independent.services)
        _ = NSApplication.shared
        let window = NSWindow(contentViewController: sidebar)
        window.setContentSize(NSSize(width: 260, height: 900))
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            window.contentViewController = nil
            withExtendedLifetime((environment, independent)) {}
        }
        sidebar.view.layoutSubtreeIfNeeded()
        _ = peer.view
        _ = isolated.view
        let outline = sidebar.outline
        let blank = NSPoint(x: 30, y: outline.visibleRect.maxY - 20)
        try #require(outline.row(at: blank) == -1)
        let context = try menu(in: sidebar, at: blank)
        let create = try #require(context.items.first { $0.action == #selector(SidebarViewController.newSidebarGroup(_:)) })
        #expect(NSApplication.shared.sendAction(try #require(create.action), to: create.target, from: create))
        let sheet = try #require(window.attachedSheet)
        let field = try #require(sheet.initialFirstResponder as? NSTextField)
        field.stringValue = "  Projects  "
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        let group = try #require(preferences.sidebarGroups.first)
        #expect(group.name == "Projects")
        #expect(peer.sections.contains { $0.groupID == group.id } && independent.preferences.sidebarGroups.isEmpty)
        #expect(!isolated.sections.contains { $0.groupID != nil })

        let section = try #require(sidebar.sections.first { $0.groupID == group.id })
        let folder = tree.url("folder/").lexicallyStandardized
        let files = FileDrag(tree.url("note.txt"))
        #expect(sidebar.outlineView(outline, validateDrop: files, proposedItem: section, proposedChildIndex: -1) == [])
        let folders = FileDrag([folder, folder], offering: [.copy, .move, .generic])
        #expect(sidebar.outlineView(outline, validateDrop: folders, proposedItem: section, proposedChildIndex: -1) == .generic)
        #expect(sidebar.outlineView(outline, acceptDrop: folders, item: section, childIndex: -1))
        for _ in 0..<200 where preferences.sidebarGroups.first?.folderPaths != [folder.path] {
            try await Task.sleep(for: .milliseconds(10))
        }
        let row = try #require(sidebar.sections.first { $0.groupID == group.id }?.items.first)
        #expect(row.url?.path == folder.path)
        let other = tree.url("other/").lexicallyStandardized
        let moreFolders = FileDrag(other)
        #expect(sidebar.outlineView(outline, validateDrop: moreFolders, proposedItem: row, proposedChildIndex: -1) == .copy)
        #expect(sidebar.outlineView(outline, acceptDrop: moreFolders, item: row, childIndex: -1))
        for _ in 0..<200 where preferences.sidebarGroups.first?.folderPaths != [folder.path, other.path] {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: preferences.domainName)), domainName: preferences.domainName)
        #expect(reopened.sidebarGroups.first?.folderPaths == [folder.path, other.path])

        let savedSection = try #require(sidebar.sections.first { $0.groupID == group.id })
        let groupMenu = try menu(in: sidebar, for: savedSection)
        let hide = try #require(groupMenu.items.first { $0.representedObject as? String == savedSection.id })
        #expect(NSApplication.shared.sendAction(try #require(hide.action), to: hide.target, from: hide))
        #expect(!sidebar.sections.contains { $0.groupID == group.id })
        let restoreMenu = try #require(menu(in: sidebar, at: blank).items.compactMap(\.submenu).first)
        let restore = try #require(restoreMenu.items.first { $0.representedObject as? String == savedSection.id })
        #expect(NSApplication.shared.sendAction(try #require(restore.action), to: restore.target, from: restore))
        #expect(sidebar.sections.first { $0.groupID == group.id }?.items.map(\.url?.path) == [folder.path, other.path])
        #expect(tree.snapshot() == ["folder/", "note.txt", "other/"])
    }

    @Test func recentsCanBeRemovedAndRestoredIndependentlyOfOtherFavorites() throws {
        let tree = try TestTree("favorite/"), environment = try IndependentEnvironment(), other = try IndependentEnvironment()
        defer { withExtendedLifetime((environment, other)) {} }
        let folder = tree.url("favorite/").lexicallyStandardized
        let preferences = environment.services.preferences
        preferences.favoritePaths = [folder.path]
        let sidebar = SidebarViewController(services: environment.services)
        let peer = SidebarViewController(services: environment.services)
        let independent = SidebarViewController(services: other.services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        sidebar.view.layoutSubtreeIfNeeded()
        _ = peer.view
        _ = independent.view

        func favorites(in sidebar: SidebarViewController) throws -> SidebarSection {
            try #require(sidebar.sections.first { $0.kind == .favorites })
        }

        var navigations = 0
        sidebar.onSelect = { _ in navigations += 1 }
        sidebar.highlight(.recents)
        let recents = try #require(favorites(in: sidebar).items.first)
        #expect(recents.target == .recents && sidebar.outline.selectedRow >= 0)
        let contextMenu = try menu(in: sidebar, for: recents)
        let remove = try #require(contextMenu.items.first { $0.title == String(localized: "Remove from Sidebar") })
        #expect(NSApplication.shared.sendAction(try #require(remove.action), to: remove.target, from: remove))
        #expect(try favorites(in: sidebar).items.map(\.target) == [.folder(folder)])
        #expect(try favorites(in: peer).items.map(\.target) == [.folder(folder)])
        #expect(try favorites(in: independent).items.first?.target == .recents)
        #expect(sidebar.outline.selectedRow == -1 && navigations == 0)
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: preferences.domainName)), domainName: preferences.domainName)
        #expect(reopened.sidebarHidesRecents)

        let headerMenu = try menu(in: sidebar, for: favorites(in: sidebar))
        let restore = try #require(headerMenu.items.first { $0.title == String(localized: "Show in Sidebar") }?.submenu)
        let show = try #require(restore.items.first { $0.title == recents.title })
        #expect(NSApplication.shared.sendAction(try #require(show.action), to: show.target, from: show))
        #expect(try favorites(in: sidebar).items.map(\.target) == [.recents, .folder(folder)])
        #expect(try favorites(in: peer).items.map(\.target) == [.recents, .folder(folder)])
        #expect(sidebar.outline.selectedRow >= 0 && navigations == 0)
        #expect(!reopened.sidebarHidesRecents)
        #expect(preferences.favoritePaths == [folder.path])
    }

    @Test func sectionMenusHideAndRestoreGroupsAcrossSidebars() throws {
        let tree = try TestTree("often/"), environment = try IndependentEnvironment(), other = try IndependentEnvironment()
        let folder = tree.url("often").lexicallyStandardized
        environment.services.visits.record(folder)
        let sidebar = SidebarViewController(services: environment.services)
        let peer = SidebarViewController(services: environment.services)
        let independent = SidebarViewController(services: other.services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        sidebar.view.layoutSubtreeIfNeeded()
        _ = peer.view
        _ = independent.view
        var navigations = 0
        sidebar.onSelect = { _ in navigations += 1 }
        sidebar.highlight(.folder(folder))
        #expect(sidebar.outline.selectedRow >= 0)

        func hide(_ kind: SidebarSection.Kind) throws {
            let section = try #require(sidebar.sections.first { $0.kind == kind })
            let headerMenu = try menu(in: sidebar, for: section)
            let item = try #require(headerMenu.items.first { $0.representedObject as? String == kind.rawValue })
            #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        }

        try hide(.frequent)
        try hide(.tags)
        #expect(!sidebar.sections.contains { $0.kind == .frequent || $0.kind == .tags })
        #expect(!peer.sections.contains { $0.kind == .frequent || $0.kind == .tags })
        #expect(independent.sections.contains { $0.kind == .tags })
        #expect(sidebar.outline.selectedRow == -1 && navigations == 0)
        let preferences = environment.services.preferences
        let reopened = Prefs(defaults: try #require(UserDefaults(suiteName: preferences.domainName)), domainName: preferences.domainName)
        #expect(reopened.hiddenSidebarSections == ["frequent", "tags"])

        for kind in sidebar.sections.compactMap(\.kind) { try hide(kind) }
        #expect(sidebar.outline.numberOfRows == 0)
        sidebar.view.layoutSubtreeIfNeeded()
        let emptyPoint = NSPoint(x: 30, y: 30)
        #expect(sidebar.outline.visibleRect.contains(emptyPoint))
        let emptyMenu = try menu(in: sidebar, at: emptyPoint)
        let restore = try #require(emptyMenu.items.compactMap(\.submenu).first)
        let frequent = try #require(restore.items.first { $0.representedObject as? String == "frequent" })
        #expect(NSApplication.shared.sendAction(try #require(frequent.action), to: frequent.target, from: frequent))
        #expect(sidebar.sections.map(\.kind) == [.frequent] && peer.sections.map(\.kind) == [.frequent])
        #expect(sidebar.sections.first?.items.first?.url?.fileViewKey == folder.fileViewKey)
        #expect(sidebar.outline.selectedRow >= 0 && navigations == 0)
        withExtendedLifetime((environment, other)) {}
    }

    @Test func duplicateLocationsKeepTheChosenSectionAcrossNavigationAndRebuilds() async throws {
        let tree = try TestTree("OrbStack/", "other/"), environment = try IndependentEnvironment()
        let base = environment.services, folder = tree.url("OrbStack")
        base.visits.record(folder)
        let services = BrowserServices.configured(transfers: base.transfers, visits: base.visits, windows: .headless,
            remote: base.remote, containers: base.containers, containerStore: base.containerStore, clipboard: base.clipboard,
            cloudFolders: { [CloudFolder(url: folder, title: "OrbStack")] })
        let sidebar = SidebarViewController(services: services)
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        await sidebar.cloudRead?.value
        var navigations = 0
        sidebar.onSelect = { [weak sidebar] target in navigations += 1; sidebar?.highlight(target) }
        func row(in section: String) throws -> Int {
            let group = try #require(sidebar.sections.first { $0.id == section })
            let item = try #require(group.items.first { $0.url?.lexicallyStandardized.fileViewKey == folder.lexicallyStandardized.fileViewKey }, "Missing fixture in \(section)")
            let row = sidebar.outline.row(forItem: item)
            try #require(row >= 0)
            return row
        }
        for section in ["locations", "frequent", "locations"] {
            sidebar.outline.selectRowIndexes([try row(in: section)], byExtendingSelection: false)
            #expect(sidebar.outline.selectedRow == (try row(in: section)))
            let clicked = navigations
            sidebar.highlight(.folder(folder))
            sidebar.reload()
            #expect(sidebar.outline.selectedRow == (try row(in: section)))
            #expect(navigations == clicked, "Rebuilding and highlighting must not navigate again")
            sidebar.highlight(.recents)
            sidebar.highlight(.folder(folder))
            #expect(sidebar.outline.selectedRow == (try row(in: section)))
        }
        let locations = try #require(sidebar.sections.first { $0.id == "locations" })
        sidebar.outline.collapseItem(locations)
        let clicked = navigations
        sidebar.highlight(.folder(folder))
        #expect(sidebar.outline.selectedRow == (try row(in: "frequent")))
        #expect(navigations == clicked)
        sidebar.outline.expandItem(locations)
        sidebar.highlight(.folder(folder))
        #expect(sidebar.outline.selectedRow == (try row(in: "locations")))
        sidebar.onSelect = nil
        #expect(tree.snapshot() == ["OrbStack/", "other/"])
        withExtendedLifetime(environment) {}
    }
}
