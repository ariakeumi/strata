import Foundation

final class SMBSharePage {
    let root: URL?
    let onReload: () -> Void
    var mode: BrowserViewMode
    var onOpen: ((String) -> Void)?

    init(root: URL?, mode: BrowserViewMode, onReload: @escaping () -> Void) {
        self.root = root
        self.mode = root != nil && mode != .treemap ? mode : .list
        self.onReload = onReload
    }
}
