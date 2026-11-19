import AppKit
import Testing
@testable import Strata
@testable import StrataSearch

@MainActor struct PaneSearchTests {
    private func shown(_ pane: Pane) -> Set<String> { Set(pane.browser.topLevelEntries.map(\.name)) }

    @Test func toolbarSearchStaysInsideTheCurrentFolderAndDoesNotFollowLinks() async throws {
        let tree = try TestTree("docs/report.txt", "docs/inner/report-old.txt", "docs/link -> ../outside",
                                "docs-other/report-lookalike.txt", "outside/report-outside.txt")
        let environment = try IndependentEnvironment()
        let window = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let field = NSSearchField()
        field.stringValue = "report"
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        await window.pane.search.task?.value
        guard case .search(let query, let scope) = window.destination else {
            Issue.record("The toolbar should enter search results")
            return
        }
        #expect(query == "report" && PathSpelling.short(scope) == PathSpelling.short(tree.url("docs")))
        #expect(shown(window.pane) == ["report.txt", "report-old.txt"])
        #expect(window.pane.search.summary.hasPrefix("2 results"))

        field.stringValue = "report in:\"\(tree.url("docs-other").path)\""
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        await window.pane.search.task?.value
        #expect(shown(window.pane).isEmpty)
    }

    @Test func searchUsesTheFocusedColumnAndTheFocusedPane() async throws {
        let tree = try TestTree("left/report-left.txt", "left/inner/report-inner.txt", "right/report-right.txt")
        let environment = try IndependentEnvironment()
        let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"),
                                             services: environment.services)
        let left = window.pane
        left.browser.setMode(.columns, remember: false)
        left.columnLocation = tree.url("left/inner")
        window.search("report", in: nil)
        let right = try #require(window.panes.last)
        window.activate(right)
        window.search("report", in: nil)
        await left.search.task?.value
        await right.search.task?.value
        #expect(shown(left) == ["report-inner.txt"])
        #expect(shown(right) == ["report-right.txt"])
    }

    @Test func leavingAndReturningDropsAnOldSearch() async throws {
        let tree = try TestTree("docs/report.txt", "docs/notes.txt")
        let environment = try IndependentEnvironment()
        let window = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        let pane = window.pane
        window.search("report", in: nil)
        let running = try #require(pane.search.task)
        window.go(.folder(tree.url("docs")))
        await running.value
        await pane.browser.directoryReads.task?.value
        #expect(running.isCancelled)
        #expect(!pane.browser.isShowingResults && shown(pane) == ["notes.txt", "report.txt"])
    }

    @Test func reloadSearchReadsNewFilesInTheSameFolder() async throws {
        let tree = try TestTree("docs/report.txt", "outside/report-outside.txt")
        let environment = try IndependentEnvironment()
        let window = BrowserWindowController(location: tree.url("docs"), services: environment.services)
        window.search("report", in: nil)
        await window.pane.search.task?.value
        #expect(shown(window.pane) == ["report.txt"])
        try Data().write(to: tree.url("docs/report-new.txt"))
        #expect(window.browser.canReloadResults)
        window.browser.reloadFolder(nil)
        await window.pane.search.task?.value
        #expect(shown(window.pane) == ["report.txt", "report-new.txt"])
    }

    @Test func anOnDemandSearchCountsAllMatchesAndKeepsTheBestRows() async throws {
        let tree = try TestTree("Café.txt", ".Café-hidden.txt", "Café.pdf", "inner/café-final.txt")
        let result = try #require(await FolderSearch.run("cafe ext:txt", in: tree.root, showHidden: false, limit: 1))
        #expect(result.total == 2)
        #expect(result.entries.map(\.name) == ["Café.txt"])
        let exact = await FolderSearch.run("Café case: ext:txt", in: tree.root, showHidden: true)
        #expect(Set(exact?.entries.map(\.name) ?? []) == ["Café.txt", ".Café-hidden.txt"])
    }
}
