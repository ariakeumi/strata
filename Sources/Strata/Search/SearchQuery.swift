import Foundation

/// Seconds since 1970 as a search query’s 32-bit timestamp, clamped.
nonisolated package func searchTimestamp(_ date: Date) -> UInt32 {
    UInt32(clamping: saturatingInt64(date.timeIntervalSince1970) ?? 0)
}

/// A parsed search: plain words match names (all must appear), plus Everything-style filters:
/// `ext:pdf;png`, `*.pdf`, `kind:image|video|audio|doc|code|archive|app|folder|file`, `size:>100mb`, `size:1mb..1gb`,
/// `modified:today|yesterday|<7d|>30d|2026`, `in:~/Documents` or `in:github` (any enclosing folder name),
/// `!word` to exclude, `"exact phrase"`, and `a/b` to match a folder named like `a` above a name like `b`.
nonisolated package struct SearchQuery: Sendable {
    package enum Kind: String, Sendable {
        case folder, file, image, video, audio, document, book, comic, code, archive, app
    }

    package var terms: [[UInt8]] = []
    package var excludedTerms: [[UInt8]] = []
    /// `a/b` terms: ancestors must match the leading parts, the name the last.
    package var pathTerms: [[[UInt8]]] = []
    package var extensions: Set<String> = []
    package var kind: Kind?
    package var minSize: Int64?
    package var maxSize: Int64?
    package var modifiedAfter: UInt32?
    package var modifiedBefore: UInt32?
    package var scopePath: String?
    package var scopeNames: [[UInt8]] = []
    package var includeHidden = false
    /// `regex:pattern`: names must match it (ignoring case unless `case:` is on). An invalid pattern matches nothing.
    package var regex: NameRegex?
    package var invalidRegex = false
    /// `case:` (the scope bar's Match Case): name words and the pattern compare letters exactly, case and accents.
    package var caseSensitive = false

    package init() {}

    package var isEmpty: Bool {
        terms.isEmpty && pathTerms.isEmpty && extensions.isEmpty && kind == nil && minSize == nil && maxSize == nil
            && modifiedAfter == nil && modifiedBefore == nil && scopeNames.isEmpty && regex == nil && !invalidRegex
    }

    package static let caseWords: Set<String> = ["case:", "case:yes", "case:on", "case:match", "case:sensitive"]
    /// Spelled out, the default: they're understood and set nothing.
    package static let noCaseWords: Set<String> = ["case:off", "case:no", "case:ignore"]

    /// Whether `text` asks for exact case (`case:`).
    package static func isCaseSensitive(_ text: String) -> Bool {
        tokenize(text).contains { caseWords.contains($0.lowercased()) }
    }

    /// `text` with `case:` added or taken out (the scope bar's Match Case), everything else as typed.
    package static func settingCase(_ on: Bool, in text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).filter {
            !caseWords.contains($0.lowercased()) && !noCaseWords.contains($0.lowercased())
        }
        return (words.map(String.init) + (on ? ["case:"] : [])).joined(separator: " ")
    }

    /// How names and terms are compared: composed Unicode, without case or accents ("Café", "cafe" and a decomposed
    /// "Cafe\u{301}" from Foundation all match).
    package static func foldText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    package static func parse(_ text: String, now: Date = .now) -> SearchQuery {
        var query = SearchQuery()
        let tokens = tokenize(text)
        query.caseSensitive = tokens.contains { caseWords.contains($0.lowercased()) }
        var pattern: String?
        for token in tokens { read(token, into: &query, pattern: &pattern, now: now) }
        finish(&query, pattern: pattern)
        return query
    }

    /// One word of a query: a case word, a regex, a filter, a scope, or a term.
    private static func read(_ token: String, into query: inout SearchQuery, pattern: inout String?, now: Date) {
        let lower = token.lowercased()
        if caseWords.contains(lower) || noCaseWords.contains(lower) { return }
        if lower.hasPrefix("regex:") || lower.hasPrefix("re:") {
            let value = String(token.drop(while: { $0 != ":" }).dropFirst())
            if !value.isEmpty { pattern = value }
        } else if readFilter(lower, into: &query, now: now) {
            return
        } else if let value = value(of: token, keys: ["in:", "In:", "IN:"]) {
            // (Folder names below are matched without case either way.)
            if value.hasPrefix("/") || value.hasPrefix("~") {
                query.scopePath = (value as NSString).expandingTildeInPath
            } else {
                let scope = foldText(value)
                if !scope.isEmpty { query.scopeNames.append(Array(scope.utf8)) }
            }
        } else {
            readTerm(token, into: &query)
        }
    }

    /// `ext:`, `*.ext`, `kind:`, `size:` or `modified:`: whether `lower` was one.
    private static func readFilter(_ lower: String, into query: inout SearchQuery, now: Date) -> Bool {
        if let value = value(of: lower, keys: ["ext:", "extension:"]) {
            query.extensions.formUnion(value.split(whereSeparator: { ";,|".contains($0) }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        } else if lower.hasPrefix("*."), lower.count > 2, !lower.dropFirst(2).contains("*") {
            // "*.tar.gz": the last extension, plus the whole suffix as part of the name.
            let suffix = String(lower.dropFirst(2))
            query.extensions.insert(String(suffix.split(separator: ".").last ?? Substring(suffix)))
            if suffix.contains(".") { query.terms.append(Array(suffix.utf8)) }
        } else if let value = value(of: lower, keys: ["kind:", "type:", "is:"]) {
            // "kind:pdf" names an extension; "kind:spreadsheet" a group of them.
            if let kind = kind(value) {
                query.kind = kind
            } else if let group = extensionGroups[value] {
                query.extensions.formUnion(group)
            } else {
                query.extensions.insert(value)
            }
        } else if let value = value(of: lower, keys: ["size:"]) {
            (query.minSize, query.maxSize) = sizeRange(value)
        } else if let value = value(of: lower, keys: ["modified:", "mod:", "date:", "dm:"]) {
            (query.modifiedAfter, query.modifiedBefore) = dateRange(value, now: now)
        } else {
            return false
        }
        return true
    }

    /// A word to leave out ("-draft"), a path ("projects/app"), or a word the name contains.
    private static func readTerm(_ token: String, into query: inout SearchQuery) {
        let lower = token.lowercased()
        // With case on, words keep their letters (composed the same way names are compared).
        let folded = query.caseSensitive ? token.precomposedStringWithCanonicalMapping : foldText(token)
        if (lower.hasPrefix("!") || lower.hasPrefix("-")) && lower.count > 1 {
            let term = folded.dropFirst()
            if !term.isEmpty { query.excludedTerms.append(Array(term.utf8)) }
        } else if lower == "!" || lower == "-" {
            return   // Half-typed exclusion: not a term yet.
        } else if lower.contains("/") {
            // Folder parts are matched without case either way; the name (the last part) follows `case:`.
            var parts = foldText(token).split(separator: "/").map { Array($0.utf8) }
            if query.caseSensitive, parts.count > 1, let name = folded.split(separator: "/").last {
                parts[parts.count - 1] = Array(name.utf8)
            }
            if parts.count == 1 { query.terms.append(parts[0]) } else if parts.count > 1 { query.pathTerms.append(parts) }
        } else if !folded.isEmpty {
            query.terms.append(Array(folded.utf8))
        }
    }

    /// The regex, once every word is read (`case:` may come after it), and whether hidden items and build or cache
    /// folders are wanted: names that start with a dot, or `in:target` (or another such folder) to look inside them.
    private static func finish(_ query: inout SearchQuery, pattern: String?) {
        if let pattern {
            if let regex = NameRegex(pattern, caseSensitive: query.caseSensitive) { query.regex = regex } else { query.invalidRegex = true }
        }
        let mentioned = (query.terms + query.pathTerms.flatMap { $0 } + query.scopeNames).map { String(decoding: $0, as: UTF8.self).lowercased() }
        let scopes = query.scopeNames.map { String(decoding: $0, as: UTF8.self) }
        query.includeHidden = mentioned.contains { $0.hasPrefix(".") } || scopes.contains { noiseWords.contains($0) }
            || scopes.contains { buildFolderWords.contains($0) }
    }

    private static let extensionGroups: [String: Set<String>] = [
        "spreadsheet": ["xls", "xlsx", "numbers", "csv", "ods", "tsv"], "spreadsheets": ["xls", "xlsx", "numbers", "csv", "ods", "tsv"],
        "presentation": ["key", "ppt", "pptx", "odp"], "presentations": ["key", "ppt", "pptx", "odp"], "slides": ["key", "ppt", "pptx", "odp"],
        "diskimage": ["dmg", "iso", "img", "sparseimage"], "pdfs": ["pdf"],
    ]

    private static let noiseWords: Set<String> = ["library", "node_modules", "caches", "deriveddata", "pods", ".git"]
    private static let buildFolderWords: Set<String> = ["target", "dist", "build", "bin", "obj", "out", "coverage"]

    package static func tokenize(_ text: String) -> [String] {
        SearchTerms.split(text).map(\.value)
    }

    private static func value(of token: String, keys: [String]) -> String? {
        for key in keys where token.hasPrefix(key) && token.count > key.count {
            return String(token.dropFirst(key.count))
        }
        return nil
    }

    private static func kind(_ value: String) -> Kind? {
        switch value {
        case "folder", "folders", "dir", "directory": .folder
        case "file", "files": .file
        case "image", "images", "photo", "photos", "picture", "pic": .image
        case "video", "videos", "movie", "movies": .video
        case "audio", "music", "sound", "song": .audio
        case "doc", "docs", "document", "documents", "text": .document
        case "book", "books", "ebook", "ebooks": .book
        case "comic", "comics": .comic
        case "code", "source", "src": .code
        case "archive", "archives", "zip", "compressed": .archive
        case "app", "apps", "application", "applications": .app
        default: nil
        }
    }

    package static func bytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [
            ("tib", 1_099_511_627_776), ("gib", 1_073_741_824), ("mib", 1_048_576), ("kib", 1024),
            ("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("t", 1e12), ("g", 1e9), ("m", 1e6), ("k", 1e3), ("b", 1),
        ]
        for (suffix, multiplier) in units where text.hasSuffix(suffix) {
            guard let number = Double(text.dropLast(suffix.count)), number.isFinite, number >= 0 else { return nil }
            return saturatingInt64(number * multiplier)
        }
        guard let number = Double(text), number.isFinite, number >= 0 else { return nil }
        return saturatingInt64(number)
    }

    private static func sizeRange(_ value: String) -> (Int64?, Int64?) {
        if let range = value.range(of: "..") {
            return (bytes(String(value[..<range.lowerBound])), bytes(String(value[range.upperBound...])))
        }
        if value.hasPrefix(">=") { return (bytes(String(value.dropFirst(2))), nil) }
        if value.hasPrefix("<=") { return (nil, bytes(String(value.dropFirst(2)))) }
        if value.hasPrefix(">") { return (bytes(String(value.dropFirst())).map { $0 == .max ? .max : $0 + 1 }, nil) }
        if value.hasPrefix("<") { return (nil, bytes(String(value.dropFirst())).map { $0 == .min ? .min : $0 - 1 }) }
        switch value {
        case "empty": return (0, 0)
        case "tiny": return (0, 10_000)
        case "small": return (10_001, 1_000_000)
        case "medium": return (1_000_001, 100_000_000)
        case "large": return (100_000_001, 1_000_000_000)
        case "huge": return (1_000_000_001, nil)
        default:
            let exact = bytes(value)
            return (exact, exact)
        }
    }

    private static func dateRange(_ value: String, now: Date) -> (UInt32?, UInt32?) {
        func instant(_ value: String) -> UInt32? {
            ISO8601DateFormatter().date(from: value.uppercased()).map(searchTimestamp)
        }
        if let range = value.range(of: "..") {
            let after = String(value[..<range.lowerBound]), before = String(value[range.upperBound...])
            return (instant(after) ?? day(after).map(searchTimestamp), instant(before) ?? day(before).map(searchTimestamp))
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func stamp(_ date: Date) -> UInt32 { searchTimestamp(date) }
        // Calendar days, not 86,400 s: a day around a daylight-saving change is 23 or 25 hours.
        func dayAfter(_ date: Date) -> Date { calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400) }
        switch value {
        case "today": return (stamp(today), nil)
        case "yesterday":
            return (stamp(calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)), stamp(today))
        case "thisweek", "week": return (stamp(now.addingTimeInterval(-7 * 86_400)), nil)
        case "thismonth", "month": return (stamp(now.addingTimeInterval(-30 * 86_400)), nil)
        default: break
        }
        if let operatorEnd = value.firstIndex(where: { !"<>=".contains($0) }), operatorEnd != value.startIndex {
            let op = value[..<operatorEnd]
            let amount = String(value[operatorEnd...])
            if let seconds = duration(amount) {
                let boundary = stamp(now.addingTimeInterval(-seconds))
                // `<7d` means "less than 7 days old"; `>30d` means "older than 30 days".
                return op.hasPrefix("<") ? (boundary, nil) : (nil, boundary)
            }
            if let stamp = instant(amount) { return op.hasPrefix("<") ? (nil, stamp) : (stamp, nil) }
            if let date = day(amount) {
                return op.hasPrefix("<") ? (nil, stamp(date)) : (stamp(date), nil)
            }
        }
        if value.count == 4, let year = Int(value),
           let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
           let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) {
            return (stamp(start), stamp(end))
        }
        if let date = day(value) { return (stamp(date), stamp(dayAfter(date))) }
        return (nil, nil)
    }

    private static func duration(_ text: String) -> Double? {
        let units: [(Character, Double)] = [("h", 3600), ("d", 86_400), ("w", 7 * 86_400), ("m", 30 * 86_400), ("y", 365 * 86_400)]
        guard let last = text.last, let unit = units.first(where: { $0.0 == last }),
              let number = Double(text.dropLast()), number.isFinite, number >= 0 else { return nil }
        let seconds = number * unit.1
        return seconds.isFinite ? seconds : nil
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}

extension SearchQuery {
    private nonisolated static let extensionsByKind: [SearchQuery.Kind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "ico", "icns", "avif"],
        .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg", "3gp"],
        .audio: ["mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "aac", "opus", "wma", "caf"],
        .document: ["pdf", "doc", "docx", "pages", "txt", "rtf", "md", "markdown", "key", "ppt", "pptx", "xls", "xlsx", "numbers", "csv", "odt", "ods", "epub", "mobi", "azw", "azw3", "djvu", "djv", "fb2", "tex"],
        .book: BookFormat.books,
        .comic: BookFormat.comics,
        .code: ["swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "py", "go", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs", "java", "kt", "rb", "php", "sh", "zsh", "json", "yaml", "yml", "toml", "html", "css", "scss", "xml", "sql", "gd", "lua", "dart", "vue", "svelte"],
        .archive: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "zst", "cbz", "cbr", "cb7", "cbt"],
    ]

    package nonisolated static func extensions(for kind: SearchQuery.Kind) -> Set<String> {
        extensionsByKind[kind] ?? []
    }

}

/// A `regex:` pattern, compiled once and shared by the threads searching. Some patterns take exponentially long on
/// some names: a name gets a moment, then counts as not matching (and is counted, so the summary can say so); a
/// search's total time on the pattern is limited too.
nonisolated package final class NameRegex: @unchecked Sendable {
    package let pattern: String
    private let expression: NSRegularExpression
    private let deadline: Date
    private static let perName: TimeInterval = 0.02

    /// Names a pattern gave up on, since launch (the search summary compares before and after).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var givenUp = 0
    package static var namesGivenUp: Int { lock.withLock { givenUp } }

    package init?(_ pattern: String, caseSensitive: Bool, budget: TimeInterval = 4) {
        // Composed like the names it's matched against ("é" typed or pasted either way).
        let composed = pattern.precomposedStringWithCanonicalMapping
        guard composed.count <= 500,
              let expression = try? NSRegularExpression(pattern: composed, options: caseSensitive ? [] : [.caseInsensitive])
        else { return nil }
        self.pattern = composed
        self.expression = expression
        deadline = Date().addingTimeInterval(budget)
    }

    package func matches(_ name: String) -> Bool {
        let start = Date()
        guard start <= deadline else {
            Self.lock.withLock { Self.givenUp += 1 }
            return false
        }
        var found = false
        var gaveUp = false
        let text = name.precomposedStringWithCanonicalMapping
        expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            if match != nil {
                found = true
                stop.pointee = true
            } else if Date().timeIntervalSince(start) > Self.perName {
                gaveUp = true
                stop.pointee = true
            }
        }
        if gaveUp { Self.lock.withLock { Self.givenUp += 1 } }
        return found
    }
}
