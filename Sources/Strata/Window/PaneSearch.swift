import AppKit

/// One cancellable search or Recents request for a pane.
@MainActor final class PaneSearch {
    private let services: BrowserServices
    private weak var pane: Pane?
    private(set) var summary = ""
    var onSummary: ((String) -> Void)?
    private(set) var task: Task<Void, Never>?

    init(pane: Pane, services: BrowserServices) {
        self.pane = pane
        self.services = services
    }

    isolated deinit { stop() }

    /// A result can publish only for the navigation and task that asked for it.
    func run(debounce: Bool = false) {
        guard let pane else { return }
        let target = pane.destination
        switch target {
        case .folder, .smb: return
        case .search, .recents: break
        }
        stop()
        let revision = pane.navigationRevision
        show(summary: "")
        if !pane.browser.isShowingResults {
            pane.browser.showMessage(symbol: "magnifyingglass", title: String(localized: "Searching…"))
        }
        guard pane.navigationRevision == revision, task == nil else { return }
        let browsing = pane.location
        let services = services
        task = Task { [weak self, weak pane] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            let result = await Self.read(target, browsing: browsing, services: services)
            guard !Task.isCancelled, let self, let pane,
                  pane.navigationRevision == revision, pane.destination == target else { return }
            task = nil
            if let message = result.message {
                pane.browser.showMessage(symbol: "magnifyingglass", title: String(localized: "Search"),
                                         message: message)
            } else {
                pane.browser.showResults(result.entries, total: result.total)
            }
            guard pane.navigationRevision == revision, task == nil else { return }
            show(summary: result.summary)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private struct Answer {
        var entries: [FileEntry] = []
        var total = 0
        var summary = ""
        var message: String?
    }

    private static func read(_ target: Destination, browsing: URL, services: BrowserServices) async -> Answer {
        switch target {
        case .folder, .smb:
            return Answer()
        case .recents:
            let entries = await services.recentFiles()
            return Answer(entries: entries, total: entries.count)
        case .search(let text, let scope):
            let name = Places.displayName(scope, copies: services.copies, names: services.folderNames)
            if let query = SpotlightQuery.parse(text) {
                return await spotlight(query, in: scope, name: name)
            }
            if Privacy.measuringWouldPrompt(scope, browsing: browsing) {
                return Answer(message: String(localized: "macOS asks before apps read this folder. Open it in Strata once, then search it."))
            }
            let before = NameRegex.namesGivenUp
            let exclusions = Privacy.searchExclusions(in: scope)
            guard let found = await FolderSearch.run(text, in: scope, showHidden: services.preferences.showHidden,
                                                     skipping: exclusions) else { return Answer() }
            var parts = [resultsSummary(total: found.total, in: name)]
            if let interpretation = found.interpretation { parts.append(interpretation.summary) }
            if NameRegex.namesGivenUp > before {
                parts.append(String(localized: "the pattern took too long on some names, so they’re left out"))
            }
            if found.incomplete { parts.append(String(localized: "These items couldn’t be read.")) }
            return Answer(entries: found.entries, total: found.total, summary: parts.joined(separator: " · "))
        }
    }

    static func recentFiles() async -> [FileEntry] {
        let since = Date.now.addingTimeInterval(-7 * 86_400)
        let predicate = NSPredicate(format: "kMDItemFSContentChangeDate >= %@ AND kMDItemContentType != %@",
                                    since as NSDate, "public.folder")
        let found = await SpotlightSearch.run(predicate, scope: Places.home, limit: 400,
                                             sortBy: "kMDItemFSContentChangeDate")
        return await readEntries(found.urls.filter { FolderSearch.contains($0, in: Places.home) })
    }

    private static func spotlight(_ query: SpotlightQuery, in scope: URL, name: String) async -> Answer {
        guard !query.unsupportedSourceFilters else {
            return Answer(message: String(localized: "Check the size and date filters. Download origin cannot be combined with name patterns, exclusions or folder filters."))
        }
        let result = await SpotlightSearch.run(query.predicate, scope: scope)
        let entries = await readEntries(result.urls.filter { FolderSearch.contains($0, in: scope) })
        var parts = [resultsSummary(total: result.total, in: name), query.summary]
        if result.total > result.urls.count {
            parts.append(String(localized: "first \(result.urls.count) shown", comment: "plural"))
        }
        if result.timedOut { parts.append(String(localized: "Spotlight took too long; results may be incomplete")) }
        return Answer(entries: entries, total: result.total, summary: parts.joined(separator: " · "))
    }

    static func resultsSummary(total: Int, in name: String) -> String {
        total == 0 ? String(localized: "No results in “\(name)”")
            : String(localized: "\(total) results in “\(name)”", comment: "plural")
    }

    private static func readEntries(_ urls: [URL]) async -> [FileEntry] {
        await OwnThread.runUnlessCancelled {
            DatalessFile.withoutMaterializing {
                urls.compactMap { url in autoreleasepool { FileEntry(url: url) } }
            }
        } ?? []
    }

    private func show(summary: String) {
        self.summary = summary
        onSummary?(summary)
    }
}
