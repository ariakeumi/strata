import AppKit
import Testing
import os
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct FolderNamesTests {
    @Test func standardLocationsUseLocalizedLabelsUntilFinderNamesArrive() async throws {
        let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)
        let applicationsWithDot = URL(filePath: "/Applications/.", directoryHint: .isDirectory)
        let otherDocuments = URL(filePath: "/Volumes/Shared/Documents", directoryHint: .isDirectory)
        let locations = [
            (Places.home.appending(path: "Desktop"), String(localized: "Desktop")),
            (Places.home.appending(path: "Documents"), String(localized: "Documents")),
            (Places.home.appending(path: "Downloads"), String(localized: "Downloads")),
            (applications, String(localized: "Applications")),
        ]
        let preferences = try Prefs.isolated()
        let finderNames = [applications.path: "Finder Applications"]
        let names = FolderNames { paths in finderNames.filter { paths.contains($0.key) } }
        let checks = PlaceChecks(preferences: preferences, visits: Frecency(preferences: preferences.defaults)) { _ in
            var snapshot = PlaceChecks.Snapshot()
            snapshot.names = finderNames
            return snapshot
        }
        func favoriteTitle(_ url: URL) -> String? {
            Places.favorites(preferences: preferences, checks: checks).first { $0.url.path == url.path }?.title
        }

        for (url, label) in locations {
            #expect(names.name(url) == label)
            #expect(favoriteTitle(url) == label)
        }
        #expect(names.name(applicationsWithDot) == String(localized: "Applications"))
        #expect(checks.name(applicationsWithDot) == String(localized: "Applications"))
        #expect(names.name(otherDocuments) == "Documents")
        #expect(checks.name(otherDocuments) == "Documents")

        let announced = OSAllocatedUnfairLock(initialState: [Set<String>]())
        let observer = NotificationCenter.default.addObserver(forName: .folderNamesRead, object: names, queue: nil) { note in
            let paths = note.userInfo?["paths"] as? Set<String> ?? []
            announced.withLock { $0.append(paths) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        checks.refresh()
        await checks.task?.value
        await names.settled()
        #expect(favoriteTitle(applications) == "Finder Applications")
        #expect(names.name(applications) == "Finder Applications")
        #expect(announced.withLock { $0 } == [[applications.path]])
    }

    @Test func picturesAndICloudUseTheirDisplayNamesBeforeTheFolderRead() throws {
        let home = Places.home
        let pictures = home.appending(path: "Pictures", directoryHint: .isDirectory)
        let library = home.appending(path: "Library", directoryHint: .isDirectory)
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        let preferences = try Prefs.isolated()
        preferences.favoritePaths = [pictures.path, iCloud.path]
        let checks = PlaceChecks(preferences: preferences, visits: Frecency(preferences: preferences.defaults)) { _ in
            PlaceChecks.Snapshot()
        }
        let names = FolderNames { _ in [:] }

        #expect(Places.favorites(preferences: preferences, checks: checks).map(\.title) ==
                [String(localized: "Pictures"), String(localized: "iCloud Drive")])
        #expect(names.name(pictures) == String(localized: "Pictures"))
        #expect(names.name(library) == String(localized: "Library"))
        #expect(names.name(iCloud) == String(localized: "iCloud Drive"))
        let otherCloudDocs = URL(filePath: "/Volumes/Share/com~apple~CloudDocs", directoryHint: .isDirectory)
        #expect(names.name(otherCloudDocs) == "com~apple~CloudDocs")
        #expect(checks.name(otherCloudDocs) == "com~apple~CloudDocs")
    }

    /// The path bar, the title and a pane's header name a folder by its own name until Finder's is read away from the
    /// main thread; only names other than the folders' own are announced; a folder being read isn't read again; and a
    /// read that hangs (a server that stopped answering) holds up only that server's folders, which wait for it rather
    /// than take another thread.
    @Test func foldersGoByTheirOwnNamesUntilFindersAreRead() async throws {
        let hold = DispatchSemaphore(value: 0), holding = CancelFlag()
        let asked = OSAllocatedUnfairLock(initialState: [[String]]())
        let gone = URL(fileURLWithPath: "/Volumes/Gone/x"), docs = URL(fileURLWithPath: "/Volumes/Share/Docs")
        let alsoGone = URL(fileURLWithPath: "/Volumes/Gone/y")
        let inside = docs.appending(path: "a")
        let names = FolderNames { paths in
            asked.withLock { $0.append(paths.sorted()) }
            if paths.contains(gone.path) {
                holding.set()
                hold.wait()
            }
            return [gone.path: "x", alsoGone.path: "y", docs.path: "Documents", inside.path: "a"]
                .filter { paths.contains($0.key) }
        }
        let announced = OSAllocatedUnfairLock(initialState: [Set<String>]())
        let observer = NotificationCenter.default.addObserver(forName: .folderNamesRead, object: names, queue: nil) {
            note in
            let paths = note.userInfo?["paths"] as? Set<String> ?? []
            announced.withLock { $0.append(paths) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(names.name(gone) == "x")
        for _ in 0..<1000 where !holding.isSet { try await Task.sleep(for: .milliseconds(5)) }
        #expect(names.name(gone) == "x" && names.name(alsoGone) == "y")
        #expect(names.name(docs) == "Docs" && names.name(inside) == "a")
        for _ in 0..<1000 where names.name(docs) != "Documents" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(names.name(docs) == "Documents")
        #expect(announced.withLock { $0 } == [[docs.path]])
        #expect(asked.withLock { $0 } == [[gone.path], [docs.path, inside.path]])
        hold.signal()
        await names.settled()
        #expect(asked.withLock { $0 } == [[gone.path], [docs.path, inside.path], [alsoGone.path]])
    }

    /// A pane's folder, read for the Inspector away from the main thread, is the one on show: going elsewhere drops
    /// the read for the folder left.
    @Test func aPanesFolderIsTheOneOnShow() async throws {
        let tree = try TestTree("left/", "shown/")
        let environment = try PreviewEnvironment(tree)
        let pane = Pane(location: tree.url("left"), services: environment.services)
        var shown: [URL?] = []
        pane.readFolderEntry(tree.url("left")) { shown.append(pane.folderEntry?.url) }
        await withCheckedContinuation { continuation in
            pane.readFolderEntry(tree.url("shown")) {
                shown.append(pane.folderEntry?.url)
                continuation.resume()
            }
        }
        #expect(shown.map { $0?.lastPathComponent } == ["shown"])
        pane.stopBackgroundWork()
        #expect(tree.snapshot().filter { !$0.hasPrefix("environment/") } == ["left/", "shown/"])
        withExtendedLifetime(environment) {}
    }
}
