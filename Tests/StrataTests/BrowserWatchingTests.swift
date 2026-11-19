import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataDev

/// A pane watches the folder it shows.
@MainActor struct BrowserWatchingTests {
    @Test func aChangeInTheWatchedFolderReadsItAgain() async throws {
        let tree = try TestTree("folder/")
        let watching = BrowserWatching()
        let changes = Mutex(0)
        // Watching once its folder is open: a change made then is caught.
        await watching.watch([tree.url("folder")], folder: tree.url("folder"),
                             changed: { changes.withLock { $0 += 1 } }, isCurrent: { true }).value
        try tree.add(["folder/new.txt"])
        for _ in 0..<500 where changes.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.withLock { $0 } > 0)
        watching.stop()
        #expect(tree.snapshot() == ["folder/", "folder/new.txt"])
    }
}
