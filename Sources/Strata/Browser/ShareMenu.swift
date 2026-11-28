import AppKit

/// Lists the services that can share the captured selection together when the submenu first opens.
final class ShareMenu: NSObject, NSMenuDelegate {
    private let menu = NSMenu()
    private let urls: [URL]
    private let load: ([URL]) async -> [NSSharingService]
    private(set) var loading: Task<Void, Never>?

    init(urls: [URL], load: @escaping ([URL]) async -> [NSSharingService] = { await ShareMenu.services(for: $0) }) {
        self.urls = urls
        self.load = load
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        addPlaceholder(String(localized: "Loading…"))
    }

    isolated deinit { loading?.cancel() }

    var item: NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Share"), action: nil, keyEquivalent: "")
        item.image = StrataCommand.share.image
        item.submenu = menu
        item.representedObject = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard loading == nil else { return }
        loading = Task { [weak self, urls, load] in
            let services = await load(urls)
            guard !Task.isCancelled else { return }
            self?.show(services)
        }
    }

    private func show(_ services: [NSSharingService]) {
        menu.removeAllItems()
        if services.isEmpty { addPlaceholder(String(localized: "None")) }
        for service in services {
            let item = NSMenuItem(title: service.menuItemTitle, action: #selector(share(_:)), keyEquivalent: "")
            item.image = service.image
            item.target = self
            item.representedObject = service
            menu.addItem(item)
        }
    }

    private func addPlaceholder(_ title: String) {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
    }

    @objc private func share(_ sender: NSMenuItem) {
        (sender.representedObject as? NSSharingService)?.perform(withItems: urls)
    }

    @concurrent private static func services(for urls: [URL]) async -> sending [NSSharingService] {
        // AppKit's replacement API opens a popover. This API supplies the services for a submenu.
        NSSharingService.sharingServices(forItems: urls)
    }
}
