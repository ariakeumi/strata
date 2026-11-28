import Foundation
import StrataSupport

extension Notification.Name {
    /// A `FolderNames` read changed the displayed names (object: the `FolderNames`, userInfo `paths`:
    /// a `Set<String>` of those folders' paths).
    package static let folderNamesRead = Notification.Name("StrataFolderNamesRead")
}

/// What Finder calls the folders along the path on show (in the path bar, the window's title and a pane's header),
/// read away from the main thread: each name asks the disk, a round trip per folder on a server, every time you move.
/// Until it's read, a standard location uses its localized label and other folders go by their own names.
package final class FolderNames {
    private static let standardNames: [String: String] = {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let home = PathSpelling.short(homeURL)
        return [
            home + "/Desktop": String(localized: "Desktop"),
            home + "/Documents": String(localized: "Documents"),
            home + "/Downloads": String(localized: "Downloads"),
            "/Applications": String(localized: "Applications"),
            home + "/Pictures": String(localized: "Pictures", comment: "Finder display name of the Pictures folder"),
            home + "/Library": String(localized: "Library", comment: "Finder display name of the user’s Library folder"),
            PathSpelling.short(CloudFolders.iCloudDrive(in: homeURL)):
                String(localized: "iCloud Drive", comment: "Finder display name of the iCloud Drive root"),
        ]
    }()

    private var names: [String: String] = [:]
    private var reads: BatchedReads<String>!

    package init(read: @escaping @Sendable ([String]) -> [String: String]) {
        reads = BatchedReads(read: read) { [weak self] found in self?.keep(found) }
    }

    /// Finder's name for the folder, as last read; its fallback until then.
    package func name(_ url: URL) -> String {
        if let name = names[url.path] { return name }
        reads.request(url.path)
        return Self.fallbackName(url)
    }

    /// A name that can be shown before asking the disk. Match the location by path, so another "Documents" keeps its name.
    package static func fallbackName(_ url: URL) -> String {
        standardNames[PathSpelling.short(url)] ?? url.lastPathComponent
    }

    package func settled() async {
        await reads.settled()
    }

    /// Announce only changes to the name that was shown before the read.
    private func keep(_ found: [String: String]) {
        if names.count > 5_000 { names.removeAll(keepingCapacity: true) }
        var renamed: Set<String> = []
        for (path, name) in found {
            let previous = names.updateValue(name, forKey: path)
                ?? Self.fallbackName(URL(filePath: path, directoryHint: .isDirectory))
            if name != previous { renamed.insert(path) }
        }
        if !renamed.isEmpty {
            NotificationCenter.default.post(name: .folderNamesRead, object: self, userInfo: ["paths": renamed])
        }
    }

    package nonisolated static func read(_ paths: [String]) -> [String: String] {
        var names: [String: String] = [:]
        for path in paths { names[path] = FileManager.default.displayName(atPath: path) }
        return names
    }
}
