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

struct PaneDividerTests {
    let testEnvironment: IndependentEnvironment

    init() throws { testEnvironment = try IndependentEnvironment() }

    @Test func statusBarPreferenceAppliesToSingleAndDualPaneWindows() async throws {
        _ = NSApplication.shared
        let tree = try TestTree("left/a", "right/b")
        let independent = try IndependentEnvironment()
        let single = BrowserWindowController(location: tree.url("left"), services: testEnvironment.services)
        let dual = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"),
                                           services: testEnvironment.services)
        let other = BrowserWindowController(location: tree.url("right"), services: independent.services)
        for controller in [single, dual, other] {
            controller.window?.setFrameAutosaveName("")
            controller.split.splitView.autosaveName = nil
        }
        defer {
            for controller in [single, dual, other] {
                controller.close()
                controller.window?.contentViewController = nil
            }
        }

        let paneStatuses = try dual.panes.map { pane in
            try #require(pane.host.view.subviews.flatMap(\.subviews).compactMap { $0 as? BrowserStatusView }.first)
        }
        #expect(!testEnvironment.preferences.showStatusBar)
        #expect(single.split.status.isHidden && dual.split.status.isHidden)
        #expect(paneStatuses.allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        for pane in dual.panes { await pane.browser.directoryReads.task?.value }
        await single.browser.directoryReads.task?.value
        #expect(paneStatuses.allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        #expect(single.browser.loading.capacityTask == nil && single.browser.volumeSpace == nil)
        single.window?.contentView?.layoutSubtreeIfNeeded()
        let heightWithoutStatus = single.browser.view.frame.height

        testEnvironment.preferences.showStatusBar = true
        #expect(!single.split.status.isHidden && dual.split.status.isHidden)
        #expect(paneStatuses.allSatisfy { !$0.isHiddenOrHasHiddenAncestor && !$0.label.stringValue.isEmpty })
        #expect(other.split.status.isHidden)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        single.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(single.browser.view.frame.height < heightWithoutStatus)
        let reopened = Prefs(defaults: testEnvironment.defaults, domainName: testEnvironment.preferences.domainName)
        #expect(reopened.showStatusBar)

        dual.toggleDualPane(at: nil)
        #expect(!dual.split.status.isHidden)
        testEnvironment.preferences.showStatusBar = false
        #expect(single.split.status.isHidden && dual.split.status.isHidden)
        single.toggleDualPane(at: tree.url("right"))
        #expect(single.split.status.isHidden)
        let newStatuses = single.panes.flatMap { $0.host.view.subviews.flatMap(\.subviews) }.compactMap { $0 as? BrowserStatusView }
        #expect(newStatuses.count == 2 && newStatuses.allSatisfy { $0.isHiddenOrHasHiddenAncestor })
    }

    @Test(arguments: [BrowserViewMode.columns, .treemap, .list, .grid, .gallery])
    func closingTheOtherPaneKeepsItsDividerOutOfTheSharedFooter(_ mode: BrowserViewMode) async throws {
        testEnvironment.preferences.showStatusBar = true
        let first = PaneHostViewController(browser: BrowserViewController(services: testEnvironment.services))
        first.browser.setMode(mode, remember: false)
        let controller = MainSplitViewController(firstPane: first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.status.text = "38 items · 1 selected · 285 GB available"
        defer { window.contentViewController = nil }

        func layout() async {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        for width in [1240.0, 960.0, 1240.0] {
            window.setContentSize(NSSize(width: width, height: 780))
            let second = PaneHostViewController(browser: BrowserViewController(services: testEnvironment.services))
            second.browser.setMode(mode, remember: false)
            controller.panes.add(second)
            controller.status.isHidden = true
            first.setStatus("First pane")
            second.setStatus("Second pane")
            await layout()
            #expect(controller.panes.splitViewItems.count == 2)

            controller.panes.remove(second)
            controller.status.isHidden = false
            first.setStatus(nil)
            await layout()
            let panes = controller.panes.view.convert(controller.panes.view.bounds, to: controller.view)
            let footer = controller.status.view.convert(controller.status.view.bounds, to: controller.view)
            #expect(controller.panes.splitViewItems.count == 1)
            try #require(panes.height > 100 && footer.height == 28)
            #expect(!panes.intersects(footer), "The pane split view must end above the shared footer, including its cached divider.")
        }
    }

    @Test func dividerStaysBetweenTheToolbarAndSharedFooter() throws {
        let panes = PaneContainerViewController(first: PaneHostViewController(browser: BrowserViewController(services: testEnvironment.services)))
        let split = panes.splitView
        split.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        // The toolbar, search bar and footer change these insets. Render the actual divider without an opaque
        // browser covering it, as Columns and Disk Usage leave the shared footer exposed.
        for (top, bottom) in [(66.0, 46.0), (96.0, 72.0), (0.0, 28.0), (0.0, 0.0)] {
            split.additionalSafeAreaInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            split.layoutSubtreeIfNeeded()
            let image = NSImage(size: split.bounds.size)
            image.lockFocusFlipped(true)
            NSColor.magenta.setFill()
            split.bounds.fill()
            split.drawDivider(in: NSRect(x: 300, y: 0, width: 1, height: 400))
            image.unlockFocus()
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let scale = CGFloat(bitmap.pixelsWide) / split.bounds.width
            func isBackground(at y: CGFloat) throws -> Bool {
                let color = try #require(bitmap.colorAt(x: Int(300.5 * scale), y: Int(y * scale))?
                    .usingColorSpace(.deviceRGB))
                let background = try #require(bitmap.colorAt(x: Int(298 * scale), y: Int(y * scale))?
                    .usingColorSpace(.deviceRGB))
                return abs(color.redComponent - background.redComponent) < 0.001
                    && abs(color.greenComponent - background.greenComponent) < 0.001
                    && abs(color.blueComponent - background.blueComponent) < 0.001
            }

            #expect(try !isBackground(at: split.safeAreaRect.midY))
            if top > 0 { #expect(try isBackground(at: top / 2)) }
            if bottom > 0 { #expect(try isBackground(at: split.bounds.height - bottom / 2)) }
        }
    }
}
