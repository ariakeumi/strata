import AppKit

// MARK: - Loading

extension ProjectInfo {
    /// Sizes measured in the last minute, so flipping the selection back to a project doesn't re-walk node_modules.
    private static var sizeCache: [String: (bytes: Int64, files: Int, date: Date)] = [:]
    private static let sizeCacheLifetime: TimeInterval = 60

    /// Loads the inspector data for a project folder. `onUpdate` receives it before artifact sizes are known,
    /// so the inspector can show it immediately. The return value has sizes. Cancel the
    /// calling task when the selection changes: the size walks stop and nil is returned.
    /// On the main actor, said so: `ProjectInfo` itself is nonisolated, and compilers have read this extension's
    /// isolation differently.
    @MainActor
    package static func load(for folder: URL,
                             onUpdate: (@MainActor (ProjectInfo) -> Void)? = nil) async -> ProjectInfo? {
        let folder = folder.lexicallyStandardized
        var info = await ProjectDetector.detect(folder)
        guard info.isProject, !Task.isCancelled else { return nil }

        // Sizes already known: measured here recently, or by the list's size column.
        let now = Date()
        for index in info.artifacts.indices {
            let paths = info.artifacts[index].urls.map(\.path)
            if paths.allSatisfy({ sizeCache[$0].map { now.timeIntervalSince($0.date) < sizeCacheLifetime } ?? false }) {
                info.artifacts[index].bytes = paths.compactMap { sizeCache[$0]?.bytes }.saturatingSum
                info.artifacts[index].files = paths.reduce(0) { $0 + (sizeCache[$1]?.files ?? 0) }
            } else if info.artifacts[index].urls.count == 1, let size = FolderSizer.cached(info.artifacts[index].urls[0]) {
                info.artifacts[index].bytes = size.bytes
                info.artifacts[index].files = size.files
            }
        }
        guard info.isMeasuring else { return info }
        onUpdate?(info)

        info.artifacts = await ProjectDetector.measure(info.artifacts)
        guard !Task.isCancelled else { return nil }
        for artifact in info.artifacts where artifact.urls.count == 1 {
            if let bytes = artifact.bytes, let files = artifact.files {
                sizeCache[artifact.urls[0].path] = (bytes, files, Date())
            }
        }
        return info
    }
}

// MARK: - Actions

package enum ProjectActions {
    /// Opens a terminal in the script's folder and runs it, leaving an interactive shell open afterwards.
    ///
    /// Writes a self-deleting `.command` file and opens it with the chosen terminal, or the first automatic choice
    /// that can open `.command` files. No AppleScript, so no Automation permission prompt. Trade-offs: the
    /// window title shows the temporary file's name; the command runs through `$SHELL -lic` so it sees the same PATH
    /// as your interactive shell (nvm, Homebrew), which costs one rc-file load.
    @discardableResult
    package static func runInTerminal(_ script: ProjectScript, projectName: String? = nil, preferences: Prefs) async -> Bool {
        let project = projectName ?? script.directory.lastPathComponent
        return await openCommandFile(named: "\(project) — \(script.name)", body: commandFile(for: script), preferences: preferences)
    }

    /// Writes `body` (a `/bin/sh` script that deletes itself first) to a `.command` file and opens it in the preferred
    /// terminal. `name` is the file's name, which the terminal shows as the window's title.
    @discardableResult
    package static func openCommandFile(named name: String, body: String, preferences: Prefs) async -> Bool {
        guard let (file, terminal) = await writeCommandFile(named: name, body: body, selected: preferences.terminal, bundleIDs: preferences.terminalBundleIDs) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration, completionHandler: nil)
        return true
    }

    /// The file, in Strata's own scratch folder, and the terminal to open it in: written and looked up away from the
    /// main thread.
    @concurrent private static func writeCommandFile(named name: String, body: String, selected: String?, bundleIDs: [String]) async -> (file: URL, terminal: URL)? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Strata Scripts", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        removeStaleCommandFiles(in: folder)
        // A folder of its own: two opened at once never overwrite each other.
        let own = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = own.appending(path: sanitize(name) + ".command")
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            return nil
        }
        return preferredTerminal(for: file, selected: selected, bundleIDs: bundleIDs).map { (file, $0) }
    }

    /// The `.command` file body: cd, echo the command, run it in a login+interactive shell, then stay in a shell.
    package static func commandFile(for script: ProjectScript) -> String {
        let directory = ShellQuote.quote(script.directory.path)
        let invocation = script.invocation
        return """
        #!/bin/sh
        # Written by Strata to run a project script. Deletes itself; safe to remove.
        rm -f -- "$0"
        cd \(directory) || exit 1
        printf '\\033[2m%s\\033[0m\\n' \(ShellQuote.quote("$ " + invocation))
        "${SHELL:-/bin/zsh}" -lic \(ShellQuote.quote(invocation))
        exec "${SHELL:-/bin/zsh}" -l

        """
    }

    private nonisolated static func preferredTerminal(for file: URL, selected: String?, bundleIDs: [String]) -> URL? {
        let capable = Set(NSWorkspace.shared.urlsForApplications(toOpen: file).map(\.lexicallyStandardized))
        return preferredTerminal(bundleIDs: bundleIDs, selected: selected, capable: capable) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    }

    nonisolated static func preferredTerminal(bundleIDs: [String], selected: String?, capable: Set<URL>,
                                             lookup: (String) -> URL?) -> URL? {
        // An explicit choice may handle scripts without declaring their type to LaunchServices.
        for id in bundleIDs {
            if let app = lookup(id), id == selected || capable.contains(app.lexicallyStandardized) { return app }
        }
        return lookup("com.apple.Terminal")
    }

    /// A `.command` file name every terminal can open: plain ASCII letters, digits, spaces, dots, dashes and
    /// underscores. (Ghostty garbles other characters in the path it runs, an em dash included, and then can't find the
    /// file.)
    package nonisolated static func sanitize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || " ._-".unicodeScalars.contains(scalar)) ? Character(scalar) : "-"
        }
        // Runs of replaced characters become one dash; no leading dot (a hidden file) or dash.
        let text = String(kept).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return text.isEmpty ? "Strata" : String(text.prefix(80))
    }

    /// The files delete themselves when they run; this catches any that never ran (each in a folder of its own, left
    /// for an hour). Anything else in `folder` is removed as itself, never through a link.
    package nonisolated static func removeStaleCommandFiles(in folder: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
