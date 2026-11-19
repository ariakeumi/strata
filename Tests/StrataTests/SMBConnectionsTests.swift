import AppKit
import Testing
@testable import Strata
@testable import StrataModel

struct SMBConnectionsTests {
    @Test func validatesSavedAddressesAndOpensSubfoldersUnderTheMountedShare() throws {
        let nested = try profile("cifs://nas.local:1445/Team%20Files/Sprint%201/", user: "ACME;amy", auto: true)
        #expect(nested.shownAddress == "smb://nas.local:1445/Team%20Files/Sprint%201")
        #expect(nested.share.path == "/Team Files")
        #expect(nested.share.port == 1445)
        #expect(nested.share.user(percentEncoded: false) == "ACME;amy")
        let root = URL(filePath: "/Volumes/Test Mount", directoryHint: .isDirectory)
        #expect(nested.folder(in: root).path == "/Volumes/Test Mount/Sprint 1")
        for input in ["https://nas/share", "smb://a:secret@nas/share", "smb://nas/share?q=1", "smb://nas/share#fragment",
                      "smb://nas:99999/share", "smb://nas/share/%2e%2e", "smb://nas/share/b%2Fc", "smb://nas/share/a%00"] {
            #expect(throws: ServerConnection.Problem.self) { try profile(input) }
        }
        #expect(try profile("nas", auto: true).share.absoluteString == "smb://nas")
        #expect(try profile("nas").share.absoluteString == "smb://nas")
    }

    @Test func sharePathCanBeEditedSeparatelyFromTheServerAndPort() throws {
        let old = try profile("smb://[2001:db8::1]:1445/Team%20Files/Work%20%231%25")
        #expect(old.shownServer == "[2001:db8::1]:1445")
        #expect(old.shownSharePath == "Team Files/Work #1%")
        let edited = try profile(old.shownServer, path: old.shownSharePath)
        #expect(edited.address == old.address)
        #expect(edited.share.path == "/Team Files")
        #expect(edited.folder(in: file("/Volumes/Team")).path == "/Volumes/Team/Work #1%")
        #expect(try profile("smb://nas/old", path: "/Team Files/").address == URL(string: "smb://nas/Team%20Files"))
        #expect(try profile(old.shownServer).shownSharePath.isEmpty)
        for path in ["Team/..", "Team/.", "Team/Work\\Here", "Team/a\u{0}b"] {
            #expect(throws: ServerConnection.Problem.self) { try profile("nas", path: path) }
        }
    }

    @Test func savedMountMatchesOnlyTheChosenShareAndAccount() throws {
        let env = try IndependentEnvironment()
        let connections = env.services.smb
        let saved = try profile("smb://nas:1445/Team%20Files/Work", user: "amy")
        let candidates = [
            volume("/Volumes/Same label", remount: "smb://amy@other:1445/Team%20Files"),
            volume("/Volumes/Default port", remount: "smb://amy@nas/Team%20Files"),
            volume("/Volumes/Other login", remount: "smb://bob@nas:1445/Team%20Files"),
            volume("/Volumes/Lookalike", remount: "smb://amy@nas:1445/Team%20Files2"),
            volume("/Volumes/Local", remount: nil),
            volume("/Volumes/Chosen", remount: "cifs://amy@NAS:1445/team%20files/"),
        ]
        #expect(connections.mountedVolume(for: saved, in: candidates) == candidates.last)
        #expect(connections.mountedVolume(for: saved, in: Array(candidates.dropLast())) == nil)
        let secondMatch = volume("/Volumes/Second", remount: "smb://amy@nas:1445/Team%20Files")
        #expect(connections.mountedVolume(for: saved, in: candidates + [secondMatch]) == nil)
        #expect(connections.contains(file("/Volumes/Chosen/Work/child"), profile: saved, in: candidates))
        #expect(!connections.contains(file("/Volumes/Chosen/Work2"), profile: saved, in: candidates))
        #expect(!connections.contains(file("/Volumes/Other login/Work"), profile: saved, in: candidates))
        let original = URL(string: "smb://nas/share")!
        let replacement = URL(string: "smb://bob@nas/share")!
        #expect(!ServerConnection.matchesSMB(replacement, share: original, guest: false, exactAccount: true))
    }

    @Test func savedShareAppearsInBothSidebarModesAndOpensInItsOriginalPane() async throws {
        _ = NSApplication.shared
        let files = try TestTree("origin/", "other/", "mount/", "mount/Open Here/")
        let root = files.url("mount")
        let driver = Mounts()
        let env = try IndependentEnvironment(smbMounter: driver.mounter)
        let services = env.services
        let profile = try profile("nas/Team/Open Here")
        try await services.smb.save(profile, replacing: nil, password: "")
        let secondEnvironment = try IndependentEnvironment()
        #expect(secondEnvironment.services.smb.profiles.isEmpty)

        let sidebar = SidebarViewController(services: services)
        _ = sidebar.view
        #expect(sidebar.sections.first { $0.id == "servers" }?.items.map(\.target) == [.smb(profile.id)])
        let tree = FolderTreeController(services: services, watchBudget: .init(limit: 1))
        #expect(tree.currentRoots().filter { $0.kind == .smb(profile.id) }.map(\.title) == [profile.title])

        let controller = BrowserWindowController(location: files.url("origin"), secondPane: files.url("other"), services: services)
        let first = try #require(controller.panes.first), second = try #require(controller.panes.last)
        let work = try #require(controller.openSMB(profile.id))
        await driver.waitForStarts(1)
        controller.activate(second)
        await driver.finish(0, with: .success(root))
        await work.value
        #expect(PathSpelling.short(first.location) == PathSpelling.short(files.url("mount/Open Here")))
        #expect(PathSpelling.short(second.location) == PathSpelling.short(files.url("other")))

        controller.activate(first)
        let stale = try #require(controller.openSMB(profile.id))
        await driver.waitForStarts(2)
        controller.navigate(to: files.url("origin"))
        await driver.finish(1, with: .success(root))
        await stale.value
        #expect(PathSpelling.short(first.location) == PathSpelling.short(files.url("origin")))
        #expect(PathSpelling.short(second.location) == PathSpelling.short(files.url("other")))
        withExtendedLifetime((files, env, secondEnvironment)) {}
    }

    @Test(arguments: [false, true])
    func aMountedShareFolderCanBeDraggedIntoFavorites(ontoHeader: Bool) async throws {
        _ = NSApplication.shared
        let files = try TestTree("origin/", "mount/", "mount/Team/", "mount/Team/notes.txt", "mount/Team Other/")
        let driver = Mounts()
        let env = try IndependentEnvironment(smbMounter: driver.mounter)
        let services = env.services
        let existing = files.url("origin").lexicallyStandardized.path
        let chosen = files.url("mount/Team").lexicallyStandardized.path
        env.preferences.favoritePaths = [existing]
        env.preferences.sidebarHidesRecents = false
        env.preferences.collapsedSidebarSections = ontoHeader ? ["favorites"] : []
        let saved = try profile("nas/Share")
        try await services.smb.save(saved, replacing: nil, password: "")

        let controller = BrowserWindowController(location: files.url("origin"), services: services)
        let mount = try #require(controller.openSMB(saved.id))
        await driver.waitForStarts(1)
        await driver.finish(0, with: .success(files.url("mount")))
        await mount.value
        let browser = try #require(controller.panes.first?.browser)
        await browser.directoryReads.task?.value
        let folder = try #require(browser.rows.first { PathSpelling.short($0.url) == chosen })
        let writer = try #require(browser.outlineView(browser.outlineView, pasteboardWriterForItem: folder))
        let mask = FileDrop.sourceOperations(local: true)
        let drag = FileDrag([], offering: mask, source: browser.outlineView)
        #expect(drag.draggingPasteboard.writeObjects([writer]))

        let sidebar = controller.split.sidebar, outline = sidebar.outline
        let favorites = try #require(sidebar.sections.first { $0.kind == .favorites })
        let index = ontoHeader ? NSOutlineViewDropOnItemIndex : 1 // After Recents, before the existing favorite.
        let expected = ontoHeader ? [existing, chosen] : [chosen, existing]
        #expect(sidebar.outlineView(outline, validateDrop: drag, proposedItem: favorites, proposedChildIndex: index) == .generic)
        #expect(sidebar.outlineView(outline, acceptDrop: drag, item: favorites, childIndex: index))
        for _ in 0..<200 where env.preferences.favoritePaths != expected { try await Task.sleep(for: .milliseconds(10)) }
        #expect(env.preferences.favoritePaths == expected)
        #expect(services.transfers.jobs.isEmpty)
        #expect(files.snapshot() == ["mount/", "mount/Team Other/", "mount/Team/", "mount/Team/notes.txt", "origin/"])
    }

    @Test(arguments: [false, true])
    func serverRootListsSharesInTheOriginalPaneAndMountsOnlyTheSelectedShare(treeMode: Bool) async throws {
        _ = NSApplication.shared
        let files = try TestTree("origin/", "origin/local.txt", "other/", "mount/")
        let driver = Mounts()
        let env = try IndependentEnvironment(smbMounter: driver.mounter)
        env.preferences.sidebarShowsTree = treeMode
        let saved = try profile("smb://nas.local:1445", user: "ACME;amy")
        try await env.services.smb.save(saved, replacing: nil, password: "")
        let controller = BrowserWindowController(location: files.url("origin"), secondPane: files.url("other"), services: env.services)
        let first = try #require(controller.panes.first), second = try #require(controller.panes.last)
        first.browser.setMode(.columns, remember: false)
        let sidebar = controller.split.sidebar
        let outline: NSOutlineView
        if treeMode {
            let tree = try #require(sidebar.children.compactMap { $0 as? FolderTreeController }.first)
            outline = try #require(tree.focusView as? NSOutlineView)
        } else {
            outline = sidebar.outline
        }
        let row = try #require((0..<outline.numberOfRows).first { row in
            if let item = outline.item(atRow: row) as? SidebarItem { return item.target == .smb(saved.id) }
            if let node = outline.item(atRow: row) as? FolderNode { return node.kind == .smb(saved.id) }
            return false
        })
        outline.selectRowIndexes([row], byExtendingSelection: false)
        #expect(outline.selectedRow == row)
        let listing = try #require(first.opening.task)
        await driver.waitForLists(1)
        controller.activate(second)
        await driver.finishList(0, names: ["Team #1%", "Archive", "Team #1%", "../other", ".", "a\\b"])
        await listing.value

        #expect(first.destination == .smb(saved.id, title: saved.title))
        #expect(second.destination == .folder(files.url("other").lexicallyStandardized))
        let browser = first.browser
        #expect(browser.effectiveMode == .columns)
        #expect(!browser.supportsMode(.treemap))
        #expect(browser.rows.map(\.entry.name) == ["Archive", "Team #1%"])
        #expect(await driver.listed == [saved.address])

        let rowNode = try #require(browser.rows.last)
        #expect(rowNode.url.user(percentEncoded: false) == nil)
        #expect(rowNode.url.path(percentEncoded: false) == "/Team #1%")
        browser.select([rowNode.url])
        #expect(browser.columns.activeDirectory == browser.smbShares?.root)
        let drag = FileDrag(files.url("origin/local.txt"))
        for mode in [BrowserViewMode.list, .grid, .gallery, .columns] {
            browser.setMode(mode, remember: false)
            #expect(browser.effectiveMode == mode)
            #expect(browser.presentationSelection.map(\.url) == [rowNode.url])
            #expect(browser.targetDirectory == nil)
            #expect(browser.selectedURLs.isEmpty)
            #expect(!browser.validateMenuItem(StrataCommand.moveToTrash.menuItem()))
            #expect(!browser.validateMenuItem(StrataCommand.renameSelection.menuItem()))
            #expect(browser.validateMenuItem(StrataCommand.openSelection.menuItem()))
            if let collection = browser.activeView as? FileItemCollection {
                #expect(collection.pasteboardWriter(at: IndexPath(item: 1, section: 0)) == nil)
                #expect(!collection.acceptDrop(drag, indexPath: IndexPath(item: 1, section: 0), dropOperation: .on))
            }
        }
        #expect(browser.outlineView.tableColumn(withIdentifier: .location)?.isHidden == true)
        #expect(browser.outlineView(browser.outlineView, pasteboardWriterForItem: rowNode) == nil)
        #expect(browser.outlineView(browser.outlineView, validateDrop: drag, proposedItem: rowNode, proposedChildIndex: -1).isEmpty)
        #expect(!browser.outlineView(browser.outlineView, acceptDrop: drag, item: rowNode, childIndex: -1))
        #expect(await driver.inputs.isEmpty)
        #expect(browser.handle(.returnKey))
        let mount = try #require(first.opening.task)
        await driver.waitForStarts(1)
        let mounted = try #require(await driver.inputs.first?.url)
        #expect(mounted.host == "nas.local")
        #expect(mounted.port == 1445)
        #expect(mounted.user(percentEncoded: false) == "ACME;amy")
        #expect(mounted.path(percentEncoded: true) == "/Team%20%231%25")
        await driver.finish(0, with: .success(files.url("mount")))
        await mount.value
        #expect(first.destination == .folder(files.url("mount").lexicallyStandardized))
        #expect(first.browser.smbShares == nil)
        #expect(second.destination == .folder(files.url("other").lexicallyStandardized))

        #expect(controller.navigateHistory(.back, in: first))
        let back = try #require(first.opening.task)
        await driver.waitForLists(2)
        await driver.finishList(1, names: ["Archive"])
        await back.value
        #expect(first.browser.rows.map(\.entry.name) == ["Archive"])
        #expect(files.snapshot().contains("origin/local.txt"))
    }

    @Test func readingSharesDropsLateResultsAfterReloadAndNavigation() async throws {
        _ = NSApplication.shared
        let files = try TestTree("origin/", "other/")
        let driver = Mounts()
        let env = try IndependentEnvironment(smbMounter: driver.mounter)
        let saved = try profile("nas")
        try await env.services.smb.save(saved, replacing: nil, password: "")
        let controller = BrowserWindowController(location: files.url("origin"), services: env.services)
        let first = try #require(controller.panes.first)
        let stale = try #require(controller.openSMB(saved.id))
        await driver.waitForLists(1)
        first.browser.reloadFolder(nil)
        let latest = try #require(first.opening.task)
        await driver.waitForLists(2)
        await driver.finishList(1, names: ["Current"])
        await latest.value
        await driver.finishList(0, names: ["Old"])
        await stale.value
        #expect(first.browser.rows.map(\.entry.name) == ["Current"])

        first.browser.reloadFolder(nil)
        let leaving = try #require(first.opening.task)
        await driver.waitForLists(3)
        controller.navigate(to: files.url("other"))
        await driver.finishList(2, names: ["Late"])
        await leaving.value
        #expect(first.destination == .folder(files.url("other").lexicallyStandardized))
        #expect(first.browser.smbShares == nil)
        #expect(await driver.inputs.isEmpty)
    }

    @Test func enumerationKeepsDiskSharesIncludingHiddenShares() {
        let names = SMBShareListing.diskShares([
            "Work": ["NetShareTypeStr": "Disk"],
            "Archive$": ["NetShareTypeStr": "Disk", "IsHidden": true],
            "Printer": ["NetShareTypeStr": "Printer", "PrinterShare": true],
            "IPC$": ["NetShareTypeStr": "Pipe"],
        ])
        #expect(Set(names) == ["Work", "Archive$"])
    }

    @Test func startupIsOptInAndACancelledPaneLeavesTheLaunchMountRunning() async throws {
        let driver = Mounts()
        let env = try IndependentEnvironment(smbMounter: driver.mounter)
        let connections = env.services.smb
        let automatic = try profile("nas", auto: true)
        let manual = try profile("nas/manual")
        try await connections.save(automatic, replacing: nil, password: "")
        try await connections.save(manual, replacing: nil, password: "")
        let reopened = try IndependentEnvironment(preferences: env.preferences)
        #expect(reopened.services.smb.profiles == [automatic, manual])
        let startup = connections.connectAtLaunch()
        #expect(startup.count == 1)
        #expect(connections.connectAtLaunch().isEmpty)
        await driver.waitForStarts(1)
        let clicking = Task { try await connections.connect(automatic) }
        await Task.yield()
        clicking.cancel()
        await #expect(throws: CancellationError.self) { try await clicking.value }
        #expect(connections.isConnecting(automatic.id))
        let address = try #require(URL(string: "smb://nas"))
        #expect(await driver.inputs == [.init(url: address, interactive: false)])
        await driver.finish(0, with: .success(file("/Volumes/Automatic")))
        for task in startup { await task.value }
        #expect(!connections.isConnecting(automatic.id))
        #expect(connections.failures.isEmpty)
    }

    @Test func aFailedStartupMountCanBeRetriedFromTheSidebar() async throws {
        let driver = Mounts()
        let env = try IndependentEnvironment(smbMounter: driver.mounter)
        let connections = env.services.smb
        let profile = try profile("nas/share", auto: true)
        try await connections.save(profile, replacing: nil, password: "")
        let startup = try #require(connections.connectAtLaunch().first)
        await driver.waitForStarts(1)
        let problem = ServerConnection.Problem(message: "Offline")
        await driver.finish(0, with: .failure(problem))
        await startup.value
        #expect(connections.failures[profile.id] == problem.message)

        let retry = Task { try await connections.connect(profile) }
        await driver.waitForStarts(2)
        #expect(await driver.inputs == [.init(url: profile.share, interactive: false),
                                        .init(url: profile.share, interactive: true)])
        let destination = file("/Volumes/Retry")
        await driver.finish(1, with: .success(destination))
        #expect(try await retry.value == destination)
        #expect(connections.failures.isEmpty)
    }

    @Test func editingCancelsAnOldMountAndItsFailureCannotReplaceTheNewResult() async throws {
        let driver = Mounts()
        let env = try IndependentEnvironment(smbMounter: driver.mounter)
        let connections = env.services.smb
        let old = try profile("nas/old")
        try await connections.save(old, replacing: nil, password: "")
        let waiting = Task { try await connections.connect(old) }
        await driver.waitForStarts(1)

        let current = try profile("nas/new", id: old.id)
        try await connections.save(current, replacing: old, password: "")
        await #expect(throws: CancellationError.self) { try await waiting.value }
        let retry = Task { try await connections.connect(current) }
        await driver.waitForStarts(2)
        await driver.finish(0, with: .failure(.init(message: "Old mount failed")))
        let destination = file("/Volumes/Current")
        await driver.finish(1, with: .success(destination))
        #expect(try await retry.value == destination)
        #expect(connections.failures.isEmpty)
        #expect(connections.profiles == [current])
    }

    private func profile(_ address: String, path: String = "", user: String = "", auto: Bool = false,
                         id: UUID = UUID()) throws -> SMBProfile {
        try SMBProfile.make(id: id, name: "", address: address, sharePath: path, user: user, guest: false,
                            remembersPassword: false, connectsAtLaunch: auto)
    }

    private func file(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory) }

    private func volume(_ path: String, remount: String?) -> Place {
        Place(title: path, url: file(path), symbol: remount == nil ? "internaldrive" : "network",
              isEjectable: remount != nil, remountAddress: remount.flatMap(URL.init(string:)))
    }

    private actor Mounts {
        struct Input: Equatable {
            let url: URL
            let interactive: Bool
        }
        private(set) var inputs: [Input] = []
        private(set) var listed: [URL] = []
        private var waiting: [Int: CheckedContinuation<ServerMounter.Result, Never>] = [:]
        private var started: [(Int, CheckedContinuation<Void, Never>)] = []
        private var pendingLists: [Int: CheckedContinuation<[String], Never>] = [:]
        private var startingLists: [(Int, CheckedContinuation<Void, Never>)] = []

        nonisolated var mounter: SMBMounter {
            SMBMounter(list: { url, _, _ in await self.list(url) }) { url, _, _, interactive, _ in
                await self.mount(url, interactive: interactive)
            }
        }

        private func list(_ url: URL) async -> [String] {
            let index = listed.count
            listed.append(url)
            return await withCheckedContinuation { continuation in
                pendingLists[index] = continuation
                let ready = startingLists.filter { $0.0 <= listed.count }
                startingLists.removeAll { $0.0 <= listed.count }
                for (_, waiter) in ready { waiter.resume() }
            }
        }

        func waitForLists(_ count: Int) async {
            if listed.count >= count { return }
            await withCheckedContinuation { startingLists.append((count, $0)) }
        }

        func finishList(_ index: Int, names: [String]) {
            pendingLists.removeValue(forKey: index)?.resume(returning: names)
        }

        private func mount(_ url: URL, interactive: Bool) async -> ServerMounter.Result {
            let index = inputs.count
            inputs.append(.init(url: url, interactive: interactive))
            return await withCheckedContinuation { continuation in
                waiting[index] = continuation
                let ready = started.filter { $0.0 <= inputs.count }
                started.removeAll { $0.0 <= inputs.count }
                for (_, waiter) in ready { waiter.resume() }
            }
        }

        func waitForStarts(_ count: Int) async {
            if inputs.count >= count { return }
            await withCheckedContinuation { started.append((count, $0)) }
        }

        func finish(_ index: Int, with result: ServerMounter.Result) {
            waiting.removeValue(forKey: index)?.resume(returning: result)
        }
    }
}
