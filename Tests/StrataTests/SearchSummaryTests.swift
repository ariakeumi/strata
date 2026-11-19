import Testing
@testable import Strata

@MainActor struct SearchSummaryTests {
    @Test func summaryNamesTheSearchedFolder() {
        #expect(PaneSearch.resultsSummary(total: 0, in: "Documents") == "No results in “Documents”")
        #expect(PaneSearch.resultsSummary(total: 12, in: "Documents") == "12 results in “Documents”")
    }
}
