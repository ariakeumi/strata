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

/// The folders and disks Strata offers are read away from the main thread: lists show what was last read, and a read
/// under way takes the next request after it, never two at once.
@MainActor struct PlaceChecksTests {
    @Test func sidebarLocationsHideOnlySMBVolumes() {
        let disk = Place(title: "External disk", url: URL(filePath: "/Volumes/External"), symbol: "externaldrive")
        let smb = Place(title: "SMB share", url: URL(filePath: "/Volumes/Shared"), symbol: "network", isSMB: true)
        let nfs = Place(title: "NFS share", url: URL(filePath: "/Volumes/Other"), symbol: "network")
        let snapshot = PlaceChecks.Snapshot(volumes: [disk, smb, nfs])

        #expect(snapshot.sidebarLocationVolumes == [.startupDiskFallback, disk, nfs])
        #expect(snapshot.sidebarVolumes == [.startupDiskFallback, disk, smb, nfs])
        #expect(snapshot.volumes == [disk, smb, nfs])
    }

    @Test func bothSidebarsShowTheStartupDiskWhilePlacesAreStillBeingRead() async throws {
        let state = try TestTree()
        let read = PreviewReadGate<PlaceChecks.Snapshot>()
        let environment = try PreviewEnvironment(state, readPlaces: { _ in
            (try? await read.read()) ?? PlaceChecks.Snapshot()
        })
        let services = environment.services
        let checks = services.places
        NSWorkspace.shared.notificationCenter.removeObserver(checks)
        let startup = Place.startupDiskFallback
        let renamed = Place(title: "My Startup Disk", url: startup.url, symbol: startup.symbol)
        let external = Place(title: "External", url: URL(filePath: "/Volumes/External", directoryHint: .isDirectory),
                             symbol: "externaldrive", isEjectable: true)
        let sidebar = SidebarViewController(services: services)
        _ = sidebar.view
        func diskItems() -> [SidebarItem] {
            sidebar.sections.first { $0.kind == .locations }?.items.filter { $0.url?.path == "/" } ?? []
        }
        #expect(diskItems().map(\.title) == ["Macintosh HD"])
        #expect(diskItems().first?.isEjectable == false)
        #expect(checks.snapshot.volumes.isEmpty)

        environment.preferences.sidebarShowsTree = true
        let folderTree = try #require(sidebar.children.compactMap { $0 as? FolderTreeController }.first)
        let outline = try #require(folderTree.focusView as? NSOutlineView)
        func diskNodes() -> [FolderNode] {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FolderNode }.filter { $0.url.path == "/" }
        }
        let initial = try #require(diskNodes().first)
        #expect(diskNodes().map(\.title) == ["Macintosh HD"])

        checks.refresh()
        await read.waitUntilStarted()
        #expect(diskItems().map(\.title) == ["Macintosh HD"])
        #expect(checks.snapshot.volumes.isEmpty)
        folderTree.reveal(external.url)
        #expect(!initial.isLoading)
        folderTree.reveal(startup.url)
        #expect(outline.selectedRow == outline.row(forItem: initial))

        read.finish(.success(.init(volumes: [renamed, external])))
        await checks.task?.value
        #expect(diskItems().map(\.title) == [renamed.title])
        #expect(diskNodes().map(\.title) == [renamed.title])
        #expect(diskNodes().first === initial)
        #expect(outline.selectedRow == outline.row(forItem: initial))
        #expect(checks.snapshot.volumes == [renamed, external])
        withExtendedLifetime(environment) {}
    }

    @Test func placesAreReadInTheBackgroundAndListedAsLastRead() async throws {
        let tree = try TestTree("kept/", "gone/", "file")
        let preferences = try Prefs.isolated()
        preferences.favoritePaths = ["kept", "gone", "file"].map { tree.url($0).path }
        let visits = Frecency(preferences: preferences.defaults)
        visits.record(tree.url("gone"))
        visits.record(tree.url("kept"))
        let (started, starts) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        var reads = 0
        let checks = PlaceChecks(preferences: preferences, visits: visits) { paths in
            reads += 1
            starts.yield()
            for await _ in released { break }
            return await PlaceChecks.read(paths)
        }
        // Nothing read yet: the favorites count as there, and nothing reads the disk to list them.
        #expect(checks.isFolder(tree.url("gone").path) == nil)
        #expect(Places.favorites(preferences: preferences, checks: checks).map(\.url.path)
                == ["kept", "gone", "file"].map { tree.url($0).path })
        let gone = tree.url("gone").standardizedFileURL.path
        try FileManager.default.removeItem(at: tree.url("gone"))
        // A folder no longer there is still ranked: whether it's there is the checks' to say.
        #expect(visits.ranked().map(\.path).contains(gone))

        var notices = 0
        let center = NotificationCenter.default
        let observer = center.addObserver(forName: .placesChecked, object: checks, queue: nil) { _ in
            MainActor.assumeIsolated { notices += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var iterator = started.makeAsyncIterator()
        checks.refresh()
        await iterator.next()
        // Asked again while reading: one more read after this one, never two at once.
        checks.refresh()
        checks.refresh()
        #expect(reads == 1)
        release.yield()
        await iterator.next()
        #expect(reads == 2)
        release.yield()
        await checks.task?.value
        while checks.task != nil { await checks.task?.value }
        #expect(reads == 2 && notices == 1)
        #expect(checks.isFolder(tree.url("kept").path) == true)
        #expect(checks.isFolder(tree.url("gone").path) == false && checks.isFolder(tree.url("file").path) == false)
        #expect(checks.name(tree.url("kept")) == FileManager.default.displayName(atPath: tree.url("kept").path))
        #expect(Places.favorites(preferences: preferences, checks: checks).map(\.url.path) == [tree.url("kept").path])
        #expect(!checks.snapshot.volumes.isEmpty)
        release.finish()
        #expect(tree.snapshot() == ["file", "kept/"])
    }

    @Test func aDefaultPlaceIsOfferedOnlyOnceItsFound() throws {
        let preferences = try Prefs.isolated()
        let checks = PlaceChecks(preferences: preferences, visits: Frecency(preferences: preferences.defaults)) { _ in
            PlaceChecks.Snapshot()
        }
        let developer = Places.home.appending(path: "Developer").path
        let shown = Places.favorites(preferences: preferences, checks: checks).map(\.url.path)
        #expect(!shown.contains(developer))
        #expect(shown.first == Places.home.path)
        #expect(Places.defaultCandidates.map(\.path).contains(developer))
    }

    @Test func theSidebarListsWhatWasLastRead() async throws {
        let tree = try TestTree("visited/", "missing/")
        let environment = try PreviewEnvironment(tree)
        defer { withExtendedLifetime(environment) {} }
        let services = environment.services
        services.preferences.favoritePaths = []
        services.visits.record(tree.url("visited"))
        services.visits.record(tree.url("missing"))
        let visited = tree.url("visited").standardizedFileURL.path
        let missing = tree.url("missing").standardizedFileURL.path
        try FileManager.default.removeItem(at: tree.url("missing"))
        let sidebar = SidebarViewController(services: services)
        _ = sidebar.view
        func frequent() -> [String] {
            sidebar.sections.first { $0.id == "frequent" }?.items.compactMap(\.url?.path) ?? []
        }
        sidebar.reload()
        #expect(Set(frequent()) == [visited, missing])
        services.places.refresh()
        while services.places.task != nil { await services.places.task?.value }
        #expect(frequent() == [visited])
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["visited/"])
    }
}
