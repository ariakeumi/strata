import AppKit
import Testing
@testable import Strata

/// What a pane says about results, and the list columns it lends them and gives back.
@MainActor struct PaneResultsTests {
    @Test func aCappedSearchSaysSoAndMessagesOmitTheCount() {
        let results = PaneResults()
        results.total = 5
        let all = results.status(shown: 5)
        results.total = 10
        let capped = results.status(shown: 5)
        #expect(all.count == 1 && capped.count == 1 && all != capped && capped[0].contains("10"))
        results.total = nil
        #expect(results.status(shown: 9).isEmpty)
    }

    @Test func whereBorrowsDateAndKindsWidthAndGivesItBackOnce() {
        let list = NSOutlineView()
        list.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, width) in [(NSUserInterfaceItemIdentifier.modified, 200.0), (.created, 210), (.kind, 220), (.location, 150)] {
            let column = NSTableColumn(identifier: id)
            column.width = width
            list.addTableColumn(column)
        }
        list.tableColumn(withIdentifier: .location)?.isHidden = true
        let widths = { [NSUserInterfaceItemIdentifier.modified, .created, .kind].map { list.tableColumn(withIdentifier: $0)?.width ?? 0 } }
        let results = PaneResults()
        results.makeRoomForWhere(in: list)
        #expect(widths() == [130, 130, 120] && list.tableColumn(withIdentifier: .location)?.isHidden == false)
        results.restoreColumns(in: list)
        #expect(widths() == [200, 210, 220] && list.tableColumn(withIdentifier: .location)?.isHidden == true)
        // Given back once: widths changed afterwards stay.
        list.tableColumn(withIdentifier: .kind)?.width = 300
        results.restoreColumns(in: list)
        #expect(widths() == [200, 210, 300])
    }
}
