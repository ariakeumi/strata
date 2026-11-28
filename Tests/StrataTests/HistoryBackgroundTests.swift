import AppKit
import CryptoKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// History is written away from the main thread and its window checks its rows there too: each write is of the
/// latest entries, a History opened again holds them all, and a row's Undo waits for its check.
@MainActor struct HistoryBackgroundTests {
    @Test func historyWrittenInTheBackgroundHoldsEveryChangeWhenOpenedAgain() throws {
        let tree = try TestTree("from/", "to/")
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                            key: SymmetricKey(size: .bits256))
        let history = OperationLog(storage: storage, copies: .live)
        for index in 0..<40 {
            let destination = tree.url("to/\(index).txt")
            history.recordMove("Move", [(from: tree.url("from/\(index).txt"), to: destination)],
                               fileIdentities: LandedFiles([destination]).savedKeys)
        }
        history.setUndone(try #require(history.entries.last?.id), true)
        let reopened = OperationLog(storage: storage, copies: .live)
        #expect(reopened.entries.map(\.id) == history.entries.map(\.id))
        #expect(reopened.entries.last?.undone == true)
        #expect(tree.snapshot() == ["from/", "state/", "state/Caches/", "state/history.sealed", "to/"])
    }

    @Test(arguments: [false, true])
    func startupReadKeepsEarlyChangesThroughQuit(clear: Bool) async throws {
        let tree = try TestTree("old.txt", "early.txt")
        let directory = tree.url("state"), caches = tree.url("state/Caches")
        let key = SymmetricKey(size: .bits256)
        let storage = SecureStorage.Context(directory: directory, caches: caches, key: key)
        let old = tree.url("old.txt"), early = tree.url("early.txt")
        let previous = OperationLog(storage: storage, copies: .live)
        let oldID = try #require(previous.recordCreate("Copy", [old], fileIdentities: LandedFiles([old]).savedKeys))
        OperationLog.waitForWrites()

        let release = DispatchSemaphore(value: 0)
        let startup = SecureStorage.Context(directory: directory, caches: caches) {
            #expect(!Thread.isMainThread)
            // A synchronous read regresses initialization. Bound the wait so that regression fails the test.
            #expect(release.wait(timeout: .now() + 10) == .success)
            return key
        }
        let history = OperationLog(storage: startup, copies: .live, loadInBackground: true)
        #expect(history.entries.isEmpty)
        let firstSnapshot = history.snapshot()
        if clear { history.clear() }
        let earlyID = history.recordCreate("Copy", [early], fileIdentities: LandedFiles([early]).savedKeys)
        if let earlyID { history.setUndone(earlyID, true) }
        release.signal()
        let expected = clear ? [try #require(earlyID)] : [oldID, try #require(earlyID)]

        // Quit drains writes before the main queue gets another turn to deliver the startup read.
        OperationLog.waitForWrites()
        let reopened = OperationLog(storage: storage, copies: .live)
        #expect(reopened.entries.map(\.id) == expected)
        #expect(reopened.entries.last?.undone == true)
        #expect(await firstSnapshot.loaded().map(\.id) == [oldID])
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(history.entries.map(\.id) == expected)
        #expect(history.entries.last?.undone == true)
    }

    @Test func aHistoryRowsUndoWaitsForItsCheck() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("from/", "to/a.txt")
        let storage = SecureStorage.Context(directory: tree.url("state"), caches: tree.url("state/Caches"),
                                            key: SymmetricKey(size: .bits256))
        let history = OperationLog(storage: storage, copies: .live)
        let destination = tree.url("to/a.txt")
        history.recordMove("Move", [(from: tree.url("from/a.txt"), to: destination)], fileIdentities: LandedFiles([destination]).savedKeys)
        let panel = HistoryWindowController(history: history, undoManager: nil)
        let table = NSTableView()
        func undoEnabled() throws -> Bool {
            let cell = try #require(panel.tableView(table, viewFor: nil, row: 0))
            return try #require(cell.subviews.compactMap { $0 as? NSButton }.first).isEnabled
        }
        #expect(try !undoEnabled())
        await panel.checking?.value
        #expect(try undoEnabled())
        #expect(tree.snapshot() == ["from/", "state/", "state/Caches/", "state/history.sealed", "to/", "to/a.txt"])
    }
}
