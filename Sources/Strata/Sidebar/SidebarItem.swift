import AppKit

final class SidebarSection {
    enum Kind: String, CaseIterable {
        case favorites, workspaces, searches, frequent, locations, servers, tags

        var title: String {
            switch self {
            case .favorites: String(localized: "Favorites", comment: "Sidebar section title")
            case .workspaces: String(localized: "Workspaces", comment: "Sidebar section title: saved sets of tabs and panes")
            case .searches: String(localized: "Searches", comment: "Sidebar section title: saved searches")
            case .frequent: String(localized: "Frequent", comment: "Sidebar section title: folders you open often")
            case .locations: String(localized: "Locations", comment: "Sidebar section title: disks and the Trash")
            case .servers: String(localized: "Servers", comment: "Sidebar section title: SFTP servers and S3 buckets")
            case .tags: String(localized: "Tags", comment: "Sidebar section title: Finder tags")
            }
        }
    }

    let id: String
    let title: String
    let groupID: UUID?
    var items: [SidebarItem]
    var kind: Kind? { Kind(rawValue: id) }

    init(_ kind: Kind, items: [SidebarItem]) {
        id = kind.rawValue
        title = kind.title
        groupID = nil
        self.items = items
    }

    init(group: Prefs.SidebarGroup, items: [SidebarItem]) {
        id = Self.id(forGroup: group.id)
        title = group.name
        groupID = group.id
        self.items = items
    }

    static func id(forGroup id: UUID) -> String { id.uuidString }
}

extension NSPasteboard.PasteboardType {
    /// A sidebar folder shortcut being dragged inside the sidebar (never a file URL: dropping it
    /// elsewhere mustn't move the folder).
    static let sidebarFavorite = NSPasteboard.PasteboardType("dev.strata.sidebar-favorite")
    static let sidebarSection = NSPasteboard.PasteboardType("dev.strata.sidebar-section")
}

/// Where a sidebar row takes you.
enum SidebarTarget: Equatable {
    case folder(URL)
    case recents
    case search(SavedSearch)
    /// The containers of the engine Strata found.
    case containers
    /// A saved workspace, by name: opens its window (it's never where you are, so it's never selected).
    case workspace(String)
    /// A saved SFTP server or bucket, by ID: connects and shows its files.
    case server(String)
    case smb(UUID)
}

final class SidebarItem {
    static var recentsTitle: String { String(localized: "Recents", comment: "Sidebar item: recently used files") }

    let title: String
    let target: SidebarTarget
    let groupID: UUID?
    var symbol: String
    var isEjectable = false
    /// A Finder tag's color for its dot (Tags section).
    var tint: NSColor?
    /// A Finder tag's stored name (Tags section): `title` shows it in your language, this is what's matched and removed.
    var tagName: String?
    /// Shown on hover and read by VoiceOver.
    var help: String?

    init(_ place: Place, groupID: UUID? = nil) {
        title = place.title
        target = .folder(place.url.lexicallyStandardized)
        symbol = place.symbol
        isEjectable = place.isEjectable
        self.groupID = groupID
    }

    init(title: String, target: SidebarTarget, symbol: String) {
        self.title = title
        self.target = target
        self.symbol = symbol
        groupID = nil
    }

    var url: URL? {
        if case .folder(let url) = target { return url }
        return nil
    }
}

extension SMBProfile {
    var sidebarSymbol: String { guest ? "display" : "airport.extreme" }
}
