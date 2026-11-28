import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

/// What a pane's context menu offers to change files, decided from where the selection is, with no window or disk.
struct BrowserContextMenuTests {
    private let here = URL(fileURLWithPath: "/strata-menu-fixture/a.txt")
    private let trash = Trash.home

    @Test func anItemOnThisMacIsMovedToTheTrashAndOneInATrashIsPutBackOrDeleted() {
        let local = actions([entry(here)])
        #expect(local.contains(StrataCommand.moveToTrash.action))
        #expect(!local.contains(StrataCommand.putBack.action))
        #expect(!local.contains(StrataCommand.deleteImmediately.action))
        let trashed = actions([entry(trash.appending(path: "a.txt"))])
        #expect(Array(trashed.prefix(2)) == [StrataCommand.putBack.action, StrataCommand.deleteImmediately.action])
        #expect(trashed.contains(#selector(AppDelegate.emptyTrash(_:))))
        #expect(!trashed.contains(StrataCommand.moveToTrash.action))
        // Inside a trashed folder: already in the Trash, and not put back on its own.
        let inside = actions([entry(trash.appending(path: "f/a.txt"))])
        #expect(!inside.contains(StrataCommand.moveToTrash.action))
        #expect(!inside.contains(StrataCommand.putBack.action))
    }

    @Test func aServerOrAnArchiveIsOfferedOnlyWhatItCanDo() {
        // A server has no Trash: Delete… asks and deletes for good; nothing that would change it another way.
        var server = facts([entry(here)])
        server.isOnServer = true
        let onServer = actions(server)
        #expect(onServer.contains(StrataCommand.moveToTrash.action))
        #expect(onServer.contains(StrataCommand.getInfo.action))
        for command in [StrataCommand.cut, .duplicate, .compress, .addToShelf] {
            #expect(!onServer.contains(command.action), "\(command.id)")
        }
        // An archive's or a container's copy is read-only: copying out, nothing that changes it.
        var archive = facts([entry(here)])
        archive.isInsideArchive = true
        let inArchive = actions(archive)
        #expect(inArchive.contains(StrataCommand.copy.action))
        #expect(inArchive.contains(StrataCommand.getInfo.action))
        for command in [StrataCommand.moveToTrash, .renameSelection, .cut, .duplicate, .compress] {
            #expect(!inArchive.contains(command.action), "\(command.id)")
        }
    }

    @Test func fileSharingUsesASubmenuAndSkipsContainersAndEmptySelections() throws {
        let title = String(localized: "Share")
        let selection = [entry(here)]
        let share = try #require(menu(facts(selection)).item(withTitle: title))
        #expect(share.submenu != nil)
        #expect(menu(facts([])).item(withTitle: title) == nil)

        var container = facts(selection)
        container.isInContainerCopy = true
        #expect(menu(container).item(withTitle: title) == nil)
    }

    @Test func choosingASharingServiceUsesEveryCapturedFile() async throws {
        let urls = [here, here.deletingLastPathComponent().appending(path: "ab.txt")]
        let service = RecordingShareService(title: "Test Service", image: NSImage(), alternateImage: nil) {}
        var requests: [[URL]] = []
        let share = ShareMenu(urls: urls) { selection in
            requests.append(selection)
            return [service]
        }
        let item = share.item
        let submenu = try #require(item.submenu)
        #expect(requests.isEmpty)
        #expect(submenu.items.first?.isEnabled == false)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        await share.loading?.value

        #expect(requests == [urls])
        #expect(service.shared.isEmpty)
        #expect(submenu.items.map(\.title) == [service.menuItemTitle])
        let choice = try #require(submenu.items.first)
        let action = try #require(choice.action)
        #expect(NSApplication.shared.sendAction(action, to: choice.target, from: choice))
        #expect(service.shared == urls)
    }

    private nonisolated final class RecordingShareService: NSSharingService {
        private(set) var shared: [URL] = []

        override func perform(withItems items: [Any]) {
            shared = items.compactMap { $0 as? URL }
        }
    }

    private func actions(_ selection: [FileEntry]) -> [Selector?] {
        actions(facts(selection))
    }

    private func actions(_ facts: BrowserContextMenu.Facts) -> [Selector?] {
        menu(facts).items.map(\.action)
    }

    private func menu(_ facts: BrowserContextMenu.Facts) -> NSMenu {
        BrowserContextMenu(facts: facts, target: NSObject()) { _ in }.make()
    }

    private func entry(_ url: URL) -> FileEntry {
        FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, isPackage: false, isHidden: false, isSymlink: false,
                  isVolume: false, size: nil, modified: nil, created: nil, added: nil, kind: "", contentType: nil)
    }

    private func facts(_ selection: [FileEntry]) -> BrowserContextMenu.Facts {
        BrowserContextMenu.Facts(
            selection: selection, showsHiddenFiles: false, isOnServer: false, serverHasShell: false, isInsideArchive: false,
            isInContainerCopy: false, isShowingTrash: false, clipboardHasFiles: false, canTag: false, renameTitle: "Rename",
            compressTitle: "Compress", extractTitle: "Extract", hasArchives: false,
            containers: [], canDownload: false, canRemoveDownload: false, opensAsFolder: false, folderIsStack: false,
            folderIsEngine: false, folderIsArchiveCopy: false, selectionIsStacks: false, hasStackProjects: false, appliedTags: { [:] })
    }
}
