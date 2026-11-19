import Foundation
import Synchronization

/// Searches a single folder tree on demand. Only the best matches survive the walk.
nonisolated package enum FolderSearch {
    package struct Result: Sendable {
        package let entries: [FileEntry]
        package let total: Int
        package let interpretation: SearchFilter?
        package let incomplete: Bool
    }

    package static func run(_ text: String, in folder: URL, showHidden: Bool, skipping: Set<String> = [],
                            limit: Int = 500) async -> Result? {
        let cancelled = Mutex(false)
        return await withTaskCancellationHandler {
            await OwnThread.runUnlessCancelled {
                DatalessFile.withoutMaterializing {
                    scan(text, in: folder, showHidden: showHidden, skipping: skipping, limit: max(0, min(limit, 10_000)),
                         stopped: { cancelled.withLock { $0 } })
                }
            }
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .isVolumeKey,
        .fileSizeKey, .contentModificationDateKey,
    ]

    private static func scan(_ text: String, in folder: URL, showHidden: Bool, skipping: Set<String>, limit: Int,
                             stopped: () -> Bool) -> Result {
        let query = SearchQuery.parse(text)
        let natural = NaturalQuery.interpret(text)
        let interpreted = natural?.query
        let folder = folder.resolvingSymlinksInPath().lexicallyStandardized
        var matches: [(url: URL, score: Int)] = []
        var total = 0
        var incomplete = false
        let contents = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in incomplete = true; return true })

        func compare(_ a: (url: URL, score: Int), _ b: (url: URL, score: Int)) -> Bool {
            a.score != b.score ? a.score > b.score : a.url.path < b.url.path
        }

        if let contents {
            for case let url as URL in contents {
                if stopped() { break }
                autoreleasepool {
                    if !skipping.isEmpty, skipping.contains(PathSpelling.short(url)) {
                        contents.skipDescendants()
                        return
                    }
                    guard let values = try? url.resourceValues(forKeys: keys) else {
                        contents.skipDescendants()
                        incomplete = true
                        return
                    }
                    let hidden = values.isHidden == true || url.lastPathComponent.hasPrefix(".")
                    if (hidden && !showHidden && !query.includeHidden && interpreted?.includeHidden != true)
                        || values.isPackage == true || values.isSymbolicLink == true || values.isVolume == true {
                        contents.skipDescendants()
                    }
                    guard !hidden || showHidden || query.includeHidden || interpreted?.includeHidden == true else { return }
                    let score = query.score(url, values: values, below: folder).map { $0 + (interpreted == nil ? 0 : 10_000) }
                        ?? interpreted?.score(url, values: values, below: folder)
                    guard let score else { return }
                    total += 1
                    if limit > 0 {
                        matches.append((url, score - 2 * contents.level))
                        if matches.count >= limit * 2 {
                            matches.sort(by: compare)
                            matches.removeLast(matches.count - limit)
                        }
                    }
                }
            }
        } else {
            incomplete = true
        }
        let entries = matches.sorted(by: compare).prefix(limit).compactMap { item in
            stopped() ? nil : autoreleasepool { FileEntry(url: item.url) }
        }
        return Result(entries: entries, total: total, interpretation: natural?.filter, incomplete: incomplete)
    }

    /// A path filter narrows the tree being searched. The walker always starts at the original folder.
    package static func contains(_ url: URL, in folder: URL) -> Bool {
        let root = PathSpelling.short(folder)
        let path = PathSpelling.short(url)
        return path != root && path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

extension SearchQuery {
    fileprivate nonisolated func score(_ url: URL, values: URLResourceValues, below folder: URL) -> Int? {
        guard !isEmpty || scopePath != nil, !invalidRegex else { return nil }
        if let scopePath, !FolderSearch.contains(url, in: URL(filePath: scopePath)) { return nil }
        let directory = values.isDirectory == true
        let package = values.isPackage == true
        let ext = url.pathExtension.lowercased()
        let kinds = Self.extensions(for: kind ?? .file)
        switch kind {
        case .folder: guard directory, !package else { return nil }
        case .file: guard !directory || package else { return nil }
        case .app: guard package, ext == "app" else { return nil }
        default: break
        }
        if !extensions.isEmpty || !kinds.isEmpty {
            guard !directory || package, extensions.isEmpty || extensions.contains(ext),
                  kinds.isEmpty || kinds.contains(ext) else { return nil }
        }
        if directory, minSize != nil || maxSize != nil { return nil }
        if let minSize, !(values.fileSize.map { Int64($0) >= minSize } ?? false) { return nil }
        if let maxSize, !(values.fileSize.map { Int64($0) <= maxSize } ?? false) { return nil }
        if let modifiedAfter, !(values.contentModificationDate.map { searchTimestamp($0) >= modifiedAfter } ?? false) { return nil }
        if let modifiedBefore, !(values.contentModificationDate.map { searchTimestamp($0) < modifiedBefore } ?? false) { return nil }

        let rawName = url.lastPathComponent
        let name = caseSensitive ? rawName.precomposedStringWithCanonicalMapping : Self.foldText(rawName)
        if let regex, !regex.matches(rawName) { return nil }
        func word(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
        guard !excludedTerms.contains(where: { name.contains(word($0)) }) else { return nil }
        var score = directory ? 4 : 0
        for bytes in terms {
            let term = word(bytes)
            guard name.contains(term) else { return nil }
            score += name == term ? 120 : name.hasPrefix(term) ? 70 : 20
        }

        if !scopeNames.isEmpty || !pathTerms.isEmpty {
            let ancestors = url.deletingLastPathComponent().pathComponents.dropFirst(max(0, folder.pathComponents.count - 1))
                .map(Self.foldText)
            guard scopeNames.allSatisfy({ part in ancestors.contains { $0.contains(word(part)) } }) else { return nil }
            for parts in pathTerms {
                guard let last = parts.last, name.contains(word(last)) else { return nil }
                var remaining = ancestors[...]
                for part in parts.dropLast() {
                    guard let match = remaining.firstIndex(where: { $0.contains(Self.foldText(word(part))) }) else { return nil }
                    remaining = remaining.suffix(from: remaining.index(after: match))
                }
                score += 20
            }
        }
        return score
    }
}
