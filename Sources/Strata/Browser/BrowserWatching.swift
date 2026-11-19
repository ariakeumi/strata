import Foundation

/// Watches the shown folder for changes, including both Applications directories when applicable.
@MainActor final class BrowserWatching {
    private var watchers: [DirectoryWatcher] = []
    /// The folder being watched, once its read has said which folder it is.
    /// Ends once the watched folder's watchers are open: every read of it waits for that, so none misses a change
    /// made while it reads.
    private(set) var ready: Task<Void, Never>?
    private(set) var folder: URL?
    /// Opening the folder's watchers, away from the main thread.
    private var opening: Task<Void, Never>?

    /// Opens watchers off the main actor and returns a task that reads can wait on.
    @discardableResult
    func watch(_ folders: [URL], folder: URL,
               changed: @escaping @MainActor @Sendable () -> Void, isCurrent: @escaping () -> Bool) -> Task<Void, Never> {
        stop()
        self.folder = folder
        let opened = Self.open(folders, onChange: changed)
        opening = Task { [weak self] in
            let watchers = await opened.value
            guard let self, !Task.isCancelled, isCurrent() else { return }
            self.watchers = watchers
        }
        let ready = Self.ready(opened)
        self.ready = ready
        return ready
    }

    /// Opened away from the main actor, so what waits for them never waits for it.
    nonisolated private static func open(_ folders: [URL], onChange: @escaping @MainActor @Sendable () -> Void)
        -> Task<[DirectoryWatcher], Never> {
        Task { await DirectoryWatcher.watching(folders, onChange: onChange) }
    }

    nonisolated private static func ready(_ opened: Task<[DirectoryWatcher], Never>) -> Task<Void, Never> {
        Task { _ = await opened.value }
    }

    func stop() {
        folder = nil
        ready = nil
        opening?.cancel()
        watchers = []
    }
}
