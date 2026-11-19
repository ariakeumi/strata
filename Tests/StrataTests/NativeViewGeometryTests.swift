import AppKit
import CNativeViewTestSupport
import Testing
@testable import Strata
@testable import StrataDev
@testable import StrataFiles

@MainActor struct NativeViewGeometryTests {
    @Test func dragCoordinateConversionReadsColumnsAndTheirAncestorsOffMain() async throws {
        let tree = try TestTree("folder/item.txt")
        let environment = try IndependentEnvironment()
        let browser = BrowserViewController(services: environment.services)
        browser.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        browser.load(tree.root)
        await browser.directoryReads.task?.value
        browser.setMode(.columns, remember: false)
        let pane = try #require(descendants(browser.columns.view, as: ColumnPane.self).first)
        await pane.directoryReads.task?.value
        browser.view.layoutSubtreeIfNeeded()
        let rect = NSRect(x: 4, y: 8, width: 12, height: 16)
        let expected = pane.convert(rect, to: nil)
        let result = await Task.detached {
            (STViewProbeIsMainThread(), pane.isFlipped, STReadViewIsFlipped(pane), STConvertViewRect(pane, rect))
        }.value
        #expect(!result.0 && result.1 && result.2 && result.3 == expected)
        browser.stopBackgroundWork()
        #expect(tree.snapshot() == ["folder/", "folder/item.txt"])
        withExtendedLifetime(environment) {}
    }

    @Test func constantGeometryCanBeReadThroughSwiftAndObjectiveCOffMain() async throws {
        let environment = try IndependentEnvironment()
        let grid = GridItemView(), strip = ColumnStripView(), flipped = FlippedView()
        let preview = ColumnPreviewPane(thumbnails: environment.services.thumbnails, itemInfo: environment.services.itemInfo)
        let flow = FlowView(spacing: 4, lineSpacing: 4), shimmer = ShimmerView()
        let map = TreemapView(copies: environment.services.copies), tags = TagMenuView(applied: [:]) { _ in }
        let diff = DiffView(rows: [])
        let result = await Task.detached {
            let swift = [grid.isFlipped, strip.isFlipped, flipped.isFlipped,
                         preview.isFlipped, flow.isFlipped, shimmer.isFlipped,
                         map.isFlipped, tags.isFlipped, diff.isFlipped]
            let views: [NSView] = [grid, strip, flipped, preview, flow, shimmer, map, tags, diff]
            return (STViewProbeIsMainThread(), swift, views.map(STReadViewIsFlipped), map.isOpaque && STReadViewIsOpaque(map))
        }.value
        #expect(!result.0 && result.1.allSatisfy { $0 } && result.2.allSatisfy { $0 } && result.3)
        withExtendedLifetime(environment) {}
    }

    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }
}
