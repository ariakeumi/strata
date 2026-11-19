import AppKit
import Foundation
import Synchronization
import Testing
@testable import Strata
@testable import StrataFiles
@testable import StrataModel
@testable import StrataSearch
@testable import StrataSupport

@MainActor struct FolderSizerCancellationTests {
    @Test func aCompletedReadDeliveredAfterCancellationCannotReplaceItsSuccessor() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        let delivery = FolderSizeDelivery(), reads = Mutex(0)
        let sizer = FolderSizer(reader: { _, _ in
            let value = reads.withLock { $0 += 1; return $0 }
            return FolderSize(bytes: Int64(value), files: value)
        }, deliver: delivery.callback)
        var updates: [Int64] = []
        sizer.onUpdate = { _ in if let size = FolderSizer.cached(folder) { updates.append(size.bytes) } }
        sizer.request(folder)
        let old = await delivery.take()
        sizer.cancelPending()
        sizer.request(folder)
        let current = await delivery.take()
        old()
        #expect(FolderSizer.cached(folder) == nil && updates.isEmpty)
        current()
        #expect(FolderSizer.cached(folder)?.bytes == 2 && updates == [2])
        sizer.request(folder)
        #expect(reads.withLock { $0 } == 2)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func leavingOrReleasingTheOwnerDropsDelayedFolderSizes() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        defer { FolderSizer.invalidate(folder) }
        for release in [false, true] {
            FolderSizer.invalidate(folder)
            let delivery = FolderSizeDelivery()
            var sizer: FolderSizer? = FolderSizer(reader: { _, _ in FolderSize(bytes: 10, files: 1) }, deliver: delivery.callback)
            var callbacks = 0
            sizer?.onUpdate = { _ in callbacks += 1 }
            sizer?.request(folder)
            let action = await delivery.take()
            if release { sizer = nil } else { sizer?.cancelPending() }
            action()
            #expect(FolderSizer.cached(folder) == nil && callbacks == 0)
        }
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func anAlreadyCancelledWalkDoesNotStartOrReturnASize() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder").path
        let checks = Mutex(0)
        let size = try await TestWork.run {
            FolderSizer.measure(folder) { checks.withLock { $0 += 1 }; return true }
        }
        #expect(size == nil && checks.withLock { $0 } == 1)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func releasingTheOwnerCancelsItsActiveWalk() async throws {
        let tree = try TestTree("folder/file")
        let started = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal(); started.continuation.finish(); completed.continuation.finish() }
        var sizer: FolderSizer? = FolderSizer(reader: { _, isCancelled in
            started.continuation.yield(())
            started.continuation.finish()
            resume.wait()
            completed.continuation.yield(isCancelled())
            completed.continuation.finish()
            return nil
        })
        weak let owner = sizer
        sizer?.request(tree.url("folder"))
        var beginning = started.stream.makeAsyncIterator()
        _ = await beginning.next()
        sizer = nil
        #expect(owner == nil)
        resume.signal()
        var ending = completed.stream.makeAsyncIterator()
        #expect(await ending.next() == true)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func equivalentPathSpellingsShareSizesAndInvalidateTogether() async throws {
        let tree = try TestTree("folder/file")
        let folder = tree.url("folder")
        let alias = URL(filePath: PathSpelling.short(folder), directoryHint: .notDirectory)
        defer { FolderSizer.invalidate(folder) }
        let delivery = FolderSizeDelivery()
        let sizer = FolderSizer(reader: { _, _ in FolderSize(bytes: 25, files: 1) }, deliver: delivery.callback)
        sizer.request(folder)
        let action = await delivery.take()
        action()
        #expect(FolderSizer.cached(folder)?.bytes == 25)
        #expect(FolderSizer.cached(alias)?.bytes == 25)
        FolderSizer.invalidate(alias)
        #expect(FolderSizer.cached(folder) == nil && FolderSizer.cached(alias) == nil)
        #expect(tree.snapshot() == ["folder/", "folder/file"])
    }

    @Test func targetedCancellationStopsOnlyMatchingWalks() async throws {
        let tree = try TestTree("first/a", "second/b")
        let first = tree.url("first")
        let second = tree.url("second")
        defer {
            FolderSizer.invalidate(first)
            FolderSizer.invalidate(second)
        }
        let delivery = FolderSizeDelivery()
        let cancelledFirst = Mutex(false)
        let sizer = FolderSizer(reader: { path, isCancelled in
            if path == first.path {
                cancelledFirst.withLock { $0 = isCancelled() }
                return FolderSize(bytes: 11, files: 1)
            }
            return FolderSize(bytes: 22, files: 1)
        }, deliver: delivery.callback)
        var updated: [URL] = []
        sizer.onUpdate = { updated.append($0) }
        sizer.request(first)
        sizer.request(second)
        #expect(sizer.hasPending)
        let action1 = await delivery.take()
        let action2 = await delivery.take()
        sizer.cancel { $0 == first }
        action1()
        action2()
        #expect(!sizer.hasPending)
        #expect(FolderSizer.cached(first) == nil)
        #expect(FolderSizer.cached(second)?.bytes == 22)
        #expect(updated == [second])
    }

}
