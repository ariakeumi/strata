import Foundation
import Testing
@testable import Strata

/// A results view's titles: the path bar shows a search's query, the window says it's a search, and Recents uses its own title.
struct ResultsTitleTests {
    @Test func aSearchShowsItsQueryAndRecentsItsTitle() throws {
        #expect(ResultsTitle(.folder(URL(fileURLWithPath: "/tmp"))) == nil)
        let query = "kind:file size:>500mb"
        let search = try #require(ResultsTitle(.search(query, scope: URL(filePath: "/tmp"))))
        #expect(search.pathBar.contains(query) && search.window.contains(query))
        #expect(search.pathBar != search.window)
        let recents = try #require(ResultsTitle(.recents))
        #expect(recents.pathBar == recents.window)
        #expect(recents.symbol != search.symbol)
    }
}
