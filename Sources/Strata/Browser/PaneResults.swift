import AppKit

/// The result view’s settings and match count, and the folder’s column widths to restore when leaving results.
final class PaneResults {
    private(set) var mode = BrowserViewMode.list
    private var folderIconSize: Double?

    static func supports(_ mode: BrowserViewMode) -> Bool { [.list, .grid, .gallery].contains(mode) }

    func chooseMode(_ mode: BrowserViewMode) {
        guard Self.supports(mode) else { return }
        self.mode = mode
    }

    func enter(iconSize: Double) { folderIconSize = iconSize }

    func leave() -> Double? {
        defer { folderIconSize = nil }
        return folderIconSize
    }

    var total: Int? = 0
    private var widthsBefore: [(NSUserInterfaceItemIdentifier, CGFloat)] = []

    /// The status bar's words for the `shown` rows.
    func status(shown: Int) -> [String] {
        guard let total else { return [] }
        return [total > shown ? String(localized: "Top \(shown.formatted()) of \(total) results", comment: "plural")
                              : String(localized: "\(shown) results", comment: "plural")]
    }

    /// Makes room in `list` for "Where" from Date and Kind, not from Name (the only column that gives up width on its
    /// own), remembering their widths.
    func makeRoomForWhere(in list: NSOutlineView) {
        widthsBefore = [.modified, .created, .kind].compactMap { id in list.tableColumn(withIdentifier: id).map { (id, $0.width) } }
        list.tableColumn(withIdentifier: .modified)?.width = 130
        list.tableColumn(withIdentifier: .created)?.width = 130
        list.tableColumn(withIdentifier: .kind)?.width = 120
        list.tableColumn(withIdentifier: .location)?.isHidden = false
    }

    /// Hides "Where" in `list` again and gives Date and Kind back their widths.
    func restoreColumns(in list: NSOutlineView) {
        list.tableColumn(withIdentifier: .location)?.isHidden = true
        for (id, width) in widthsBefore { list.tableColumn(withIdentifier: id)?.width = width }
        widthsBefore = []
    }
}
