import Foundation

/// What a pane showing results (a search or Recents) is called: the path bar shows a search's query, the
/// window's title and the pane's header say it's a search; nil for a folder.
struct ResultsTitle: Equatable {
    let pathBar: String
    let window: String
    let symbol: String

    init?(_ destination: Destination) {
        switch destination {
        case .folder:
            return nil
        case .search(let text, _):
            pathBar = String(localized: "“\(text)”", comment: "Path bar title while searching: the search text in quotes")
            window = String(localized: "Search: \(text)", comment: "Window title while searching; the search text")
            symbol = "magnifyingglass"
        case .recents:
            pathBar = String(localized: "Recents", comment: "Title of the view listing recently used files")
            window = pathBar
            symbol = "clock"
        case .smb(_, let title):
            pathBar = title
            window = title
            symbol = "network"
        }
    }
}
