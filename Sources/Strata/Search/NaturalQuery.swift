import Foundation

/// Plain-English searches ("pdfs from last week bigger than 10mb") become search filters. Explicit syntax
/// (`ext:`, `size:`, …) always wins; plain name searches ("invoice") are left alone.
package nonisolated enum NaturalQuery {
    package static func interpret(_ text: String) -> (query: SearchQuery, filter: SearchFilter)? {
        let syntax = SearchQuery.parse(text)
        guard syntax.extensions.isEmpty, syntax.kind == nil, syntax.minSize == nil, syntax.maxSize == nil,
              syntax.modifiedAfter == nil, syntax.modifiedBefore == nil, syntax.scopePath == nil,
              syntax.scopeNames.isEmpty, syntax.pathTerms.isEmpty, syntax.excludedTerms.isEmpty,
              syntax.regex == nil, !syntax.invalidRegex, !syntax.caseSensitive else { return nil }
        let filter = QueryInterpreter.parse(text).filter
        guard !filter.kinds.isEmpty || !filter.extensions.isEmpty || filter.minSize != nil || filter.maxSize != nil
                || filter.modifiedAfter != nil || filter.modifiedBefore != nil else { return nil }

        var query = SearchQuery()
        query.terms = (filter.nameContains + filter.keywords).map { Array(SearchQuery.foldText($0).utf8) }
        var extensions = Set(filter.extensions.map { $0.lowercased() })
        for kind in filter.kinds {
            switch kind {
            case .folder: query.kind = .folder
            case .application: query.kind = .app
            case .pdf: extensions.insert("pdf")
            case .book: extensions.formUnion(SearchQuery.extensions(for: .book))
            case .comic: extensions.formUnion(SearchQuery.extensions(for: .comic))
            case .image: extensions.formUnion(SearchQuery.extensions(for: .image))
            case .movie: extensions.formUnion(SearchQuery.extensions(for: .video))
            case .audio: extensions.formUnion(SearchQuery.extensions(for: .audio))
            case .archive: extensions.formUnion(SearchQuery.extensions(for: .archive))
            case .code: extensions.formUnion(SearchQuery.extensions(for: .code))
            case .document: extensions.formUnion(SearchQuery.extensions(for: .document))
            case .text: extensions.formUnion(["txt", "md", "markdown", "rtf", "log"])
            case .spreadsheet: extensions.formUnion(["xls", "xlsx", "numbers", "csv", "ods", "tsv"])
            case .presentation: extensions.formUnion(["key", "ppt", "pptx", "odp"])
            case .diskImage: extensions.formUnion(["dmg", "iso", "img", "sparseimage"])
            }
        }
        // A folder kind can't be combined with file extensions; extensions mean files.
        if !extensions.isEmpty, query.kind == .folder { query.kind = nil }
        query.extensions = extensions
        query.minSize = filter.minSize
        query.maxSize = filter.maxSize
        query.modifiedAfter = filter.modifiedAfter.map(searchTimestamp)
        query.modifiedBefore = filter.modifiedBefore.map(searchTimestamp)
        let mentioned = (filter.nameContains + filter.keywords).map { $0.lowercased() }
        query.includeHidden = mentioned.contains { $0.hasPrefix(".") }
        return (query, filter)
    }
}
