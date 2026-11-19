import AppKit
import Synchronization
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataFiles
@testable import StrataModel

struct BackgroundUpdateTests {
    private final class Receiver { var count = 0 }

    private func labels(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    @Test func closingComparisonCancelsProgressAndReleasesTheSheetWhileAReadIsHeld() async throws {
        let tree = try TestTree("left/", "right/"), environment = try IndependentEnvironment()
        let schedule = ControlledUpdates(), reads = HeldProgress<Int, FolderCompare.Result>()
        let control = Mutex<FolderCompare.Control?>(nil)
        var controller: CompareController? = CompareController(left: tree.url("left"), right: tree.url("right"), undo: nil,
            transfers: environment.services.transfers, read: { _, _, _, _, token, report in
                control.withLock { $0 = token }
                return await reads.read(report)
            }, scheduleProgress: schedule.schedule)
        _ = controller?.view
        await reads.started(1)
        weak let owner = controller
        controller = nil
        #expect(owner == nil && control.withLock { $0?.isCancelled == true })
        await reads.send(Array(0..<10_000), to: 0)
        #expect(schedule.count == 0)
        await reads.finish(0, with: FolderCompare.Result())
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime(environment) {}
    }

    @Test func comparisonProgressIsBoundedAndNeverOverwritesTheCompletedResult() async throws {
        let tree = try TestTree("left/", "right/"), environment = try IndependentEnvironment()
        let schedule = ControlledUpdates(), reads = HeldProgress<Int, FolderCompare.Result>()
        var controller: CompareController? = CompareController(left: tree.url("left"), right: tree.url("right"), undo: nil,
            transfers: environment.services.transfers, read: { _, _, _, _, _, report in await reads.read(report) },
            scheduleProgress: schedule.schedule)
        let view = try #require(controller?.view)
        await reads.started(1)
        await reads.send(Array(0..<10_000), to: 0)
        #expect(schedule.count == 1)
        schedule.deliverAll()
        let summary = try #require(labels(in: view).first { $0.stringValue.contains(9999.formatted()) })
        await reads.send([10_000], to: 0)
        var result = FolderCompare.Result()
        result.identical = 12
        await reads.finish(0, with: result)
        let deadline = ContinuousClock.now + .seconds(10)
        while !summary.stringValue.contains("12"), ContinuousClock.now < deadline { await Task.yield() }
        let completed = summary.stringValue
        schedule.deliverAll()
        await reads.send([20_000], to: 0)
        schedule.deliverAll()
        #expect(completed.contains("12") && summary.stringValue == completed)
        weak let owner = controller
        controller = nil
        #expect(owner == nil)
        #expect(tree.snapshot() == ["left/", "right/"])
        withExtendedLifetime(environment) {}
    }

    @Test func containerEventBurstsCoalesceBeforeTheMainQueueAndStopAfterCancellation() async {
        let schedule = ControlledUpdates(), release = DispatchSemaphore(value: 0)
        let report = Mutex<(@Sendable () -> Void)?>(nil)
        let engine = ContainerEngine(socket: "/strata-tests/no-engine.sock", name: "Fixture", apiVersion: "1.41")
        var changed = 0, ended = 0
        var watcher: EventWatcher?
        await withCheckedContinuation { started in
            watcher = EventWatcher(engine, changed: { changed += 1 }, ended: { ended += 1 }, read: { _, _, callback in
                report.withLock { $0 = callback }
                for _ in 0..<10_000 { callback() }
                started.resume()
                release.wait()
            }, schedule: schedule.schedule)
        }
        #expect(schedule.count == 1 && changed == 0)
        schedule.deliverAll()
        #expect(changed == 1)
        let callback = report.withLock { $0 }
        for _ in 0..<10_000 { callback?() }
        #expect(schedule.count == 1)
        watcher?.cancel()
        schedule.deliverAll()
        for _ in 0..<10_000 { callback?() }
        #expect(schedule.count == 0 && changed == 1 && ended == 0)
        weak let owner = watcher
        watcher = nil
        #expect(owner == nil)
        release.signal()
    }
}
