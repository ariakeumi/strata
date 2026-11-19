import AppKit

struct CollectionPosition {
    let selection: [URL]
    let lead: URL?
    let viewport: CollectionViewport?

    init(_ collection: NSCollectionView, entries: [FileEntry], lead: Int?) {
        selection = collection.selectionIndexPaths.compactMap { path in
            entries.indices.contains(path.item) ? entries[path.item].url : nil
        }
        self.lead = lead.flatMap { entries.indices.contains($0) ? entries[$0].url : nil }
        viewport = CollectionViewport.capture(collection, entries: entries)
    }
}

struct CollectionViewport {
    private let key: String
    private let offset: NSPoint

    static func capture(_ collection: NSCollectionView, entries: [FileEntry]) -> Self? {
        guard !entries.isEmpty, let visible = collection.enclosingScrollView?.documentVisibleRect,
              let attributes = collection.collectionViewLayout?.layoutAttributesForElements(in: visible) else { return nil }
        let first = attributes.filter {
            $0.representedElementCategory == .item && $0.frame.intersects(visible)
        }.min { ($0.indexPath?.item ?? .max) < ($1.indexPath?.item ?? .max) }
        guard let first, let index = first.indexPath?.item, entries.indices.contains(index) else { return nil }
        return Self(key: entries[index].url.fileViewKey,
                    offset: NSPoint(x: visible.minX - first.frame.minX, y: visible.minY - first.frame.minY))
    }

    func restore(in collection: NSCollectionView, index: (String) -> Int?) {
        guard let index = index(key), index >= 0, collection.numberOfSections > 0, index < collection.numberOfItems(inSection: 0),
              let scroll = collection.enclosingScrollView else { return }
        collection.layoutSubtreeIfNeeded()
        guard collection.numberOfSections > 0, index < collection.numberOfItems(inSection: 0) else { return }
        guard let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        let clip = scroll.contentView
        let x = min(max(0, collection.bounds.width - clip.bounds.width), max(0, frame.minX + offset.x))
        let y = min(max(-clip.contentInsets.top, collection.bounds.height - clip.bounds.height + clip.contentInsets.bottom),
                    max(-clip.contentInsets.top, frame.minY + offset.y))
        clip.scroll(to: NSPoint(x: x, y: y)); scroll.reflectScrolledClipView(clip)
    }
}
