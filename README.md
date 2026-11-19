<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Strata icon">
</p>

<h1 align="center">Strata Files</h1>

<p align="center">
  <b>The file manager your Mac deserves.</b><br> Search the current folder, see where your space went, and work from the keyboard,<br> in a native app that feels like it shipped with macOS.
</p>

<p align="center">
  <a href="https://github.com/cristipufu/strata-files/releases/latest"><img src="https://img.shields.io/github/v/release/cristipufu/strata-files?style=flat&amp;label=release&amp;color=8150cf" alt="Latest release" height="20"></a>
  <a href="#get-strata"><img src="https://img.shields.io/badge/macOS-26%2B-555555?style=flat&amp;logo=apple&amp;logoColor=white" alt="Requires macOS 26 or later" height="20"></a>
  <a href="#get-strata"><img src="https://img.shields.io/badge/Apple%20silicon-555555?style=flat" alt="For Macs with Apple silicon" height="20"></a>
</p>

<!-- readme-languages:start -->
<p align="center">
  <strong>English</strong> · <a href="docs/readme/README.ja.md">日本語</a> · <a href="docs/readme/README.ko.md">한국어</a> · <a href="docs/readme/README.ru.md">Русский</a> · <a href="docs/readme/README.uk.md">Українська</a> · <a href="docs/readme/README.zh-Hans.md">简体中文</a> · <a href="docs/readme/README.zh-Hant.md">繁體中文</a>
</p>
<!-- readme-languages:end -->

<p align="center">
  <img src="docs/screenshots/hero.png" alt="List view with live folder sizes" width="900">
</p>

---

## Why Strata

Finder is fine until you need to find something, figure out what's eating your disk, or move a few hundred files
without a beachball. Strata keeps everything you already know: the look, the shortcuts, drag and drop, Quick Look,
tabs. Then it adds what you've been missing:

- **Folder search.** Press ⌘F to find files in the current folder and its subfolders.
- **Folder sizes.** Measure space in the Inspector and Disk Usage view.
- **A keyboard-first workflow.** Jump anywhere with ⌘K, type to filter any folder, and keep your hands off the
  mouse if you like.
- **File operations without fear.** Pause and resume big copies, see conflicts side by side before replacing
  anything, and undo past operations, even after you quit.
- **Made for people who build things.** Open folders in Terminal and preview code, data and archives.

## Search the current folder

Search by name, use filters, or type a query like *"videos bigger than 500 MB"* or *"pdfs from last month"*. Use `regex:` and **Match Case** for filename searches. Queries such as `camera:iphone`, `width:>1920` and `duration:>10m` look up metadata with Spotlight. Save a search to the sidebar to run it again.

<p align="center"><img src="docs/screenshots/search.png" alt="A plain-English search showing large videos" width="820"></p>

## Jump anywhere with ⌘K

One shortcut opens a command palette with your most-used folders, items in the current folder, and Strata’s commands. Type `acme-web/` to list a project’s contents.

Turn on Settings ▸ General ▸ Search box in the Dock to find apps, folders and commands. The Dock box can also start a search in Strata’s current folder.

<p align="center"><img src="docs/screenshots/palette.png" alt="The command palette listing the contents of a project" width="820"></p>

## See where your space went

Folder sizes appear the moment you open a folder, without waiting on "Calculating…". Switch to **Disk Usage** to see
your folders as a map.

<p align="center"><img src="docs/screenshots/treemap.webp" alt="The disk usage map of a folder" width="820"></p>

## Look inside. Stay where you are.

Press **Space** to preview the selection with macOS Quick Look. The inspector offers additional format-specific previews.

| Format | What you can do |
|---|---|
| **Markdown** | Read rendered text, tables and code blocks, with Mermaid diagrams and LaTeX equations right in the document. |
| **Jupyter notebooks (`.ipynb`)** | Read Markdown, code cells and saved outputs together. |
| **Code and configuration** | Syntax highlighting, line numbers, Find and word wrap for Swift, Python, JavaScript, TypeScript, Rust, Go, C/C++, shell scripts, YAML, TOML, XML, Dockerfiles and more. |
| **JSON** | Read formatted JSON, JSONC and JSON5 without opening an editor. |
| **JSON Lines, HAR and Xcode catalogs** | Browse rows in `.jsonl`, `.ndjson`, `.har` and `.xcstrings` files. |
| **Subtitles (`.srt`, `.vtt`)** | Read cues and timestamps in a table. |
| **HTML** | Switch between the rendered page and its source. |
| **CSV, TSV and PSV** | Page through data, sort columns and copy individual cells or rectangles. |
| **SQLite** | Choose a table or view, page through its rows, sort and copy cells. |
| **Excel and OpenDocument (`.xlsx`, `.ods`)** | Switch worksheets and explore their saved values with the same table controls. |
| **Parquet** | Inspect the file schema, column types and row count. |
| **NumPy and AI models** | Inspect array shapes and tensor details in NumPy (`.npy`), SafeTensors and GGUF files. |
| **Fonts (`.ttf`, `.otf`, `.ttc`, `.woff`)** | Choose a font face, adjust the sample size and inspect glyphs without installing the font. |
| **Design files** | View the saved artwork in Krita (`.kra`), OpenRaster (`.ora`), Sketch and Procreate files. |
| **Routes (`.gpx`, `.kml`, `.geojson`)** | Explore routes on a map with distance and elevation details. |
| **Certificates and provisioning profiles** | Inspect identity, validity and signing details in `.cer`, `.crt`, `.der`, `.pem`, `.mobileprovision` and `.provisionprofile` files. |
| **STL and 3MF models** | Rotate and zoom 3D models, with triangle counts and dimensions. |
| **EPUB and comics** | Read EPUB chapters and browse comic archives. |
| **OneNote** | Navigate notebook contents and read section pages (`.one`, `.onetoc2`), or browse packaged notebooks (`.onepkg`). |
| **Archives and packages** | List ZIP, 7z, RAR, TAR, ISO and CAB contents, plus packages such as JAR, APK, IPA and WHL. |

The inspector supports text selection and copying in PDF previews, video storyboards, and audio waveforms.

## Five views. Two panes.

Icons, List, Columns, Gallery and Disk Usage, one keystroke apart (⌃⌘1–⌃⌘5, in Finder's order), with ⌘+ and ⌘− for the
text size in List and Columns. Turn on **Dual Pane** to work with two folders side by side, copy or move between them
with a keystroke, or compare and sync them.

<table>
  <tr>
    <td><strong>Icons · ⌃⌘1</strong><br><img src="docs/screenshots/grid.webp" alt="Icon view with image thumbnails"></td>
    <td><strong>List · ⌃⌘2</strong><br><img src="docs/screenshots/list.webp" alt="List view with live folder sizes"></td>
  </tr>
  <tr>
    <td><strong>Columns · ⌃⌘3</strong><br><img src="docs/screenshots/columns.webp" alt="Column view expanded through nested folders with an image preview"></td>
    <td><strong>Gallery · ⌃⌘4</strong><br><img src="docs/screenshots/gallery.webp" alt="Gallery view with a large photo preview and thumbnail filmstrip"></td>
  </tr>
  <tr>
    <td><strong>Disk Usage · ⌃⌘5</strong><br><img src="docs/screenshots/disk-usage.webp" alt="Disk Usage view mapping folders by size"></td>
    <td><strong>Dual Pane · ⌘\</strong><br><img src="docs/screenshots/dual.webp" alt="Dual Pane with project files and photos side by side"></td>
  </tr>
</table>

## Made for developers

- **Project tools in the inspector.** Strata recognizes Node, Rust, Swift, .NET, Python, Go and more. Run project scripts
  and see how much space build folders such as `node_modules` use.
- **Previews alongside your files.** Read code, Markdown, HTML, JSON, CSV, SQLite databases and archives in the inspector.

### Servers

**Connect to Server (⌥⌘K)** adds connections under **Servers** in the sidebar.

- **SFTP** uses your SSH setup: `~/.ssh/config`, keys, the agent and ProxyJump. Open in Terminal starts a shell on the server.
- **S3** supports Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO and compatible services. Secret keys stay in your keychain.
- **Familiar file commands** work across every view, including Quick Look, copying files in and out, renaming and deleting.
  Moves within a server stay on that server.

### Containers

Works with **Docker Desktop, OrbStack, Colima, Podman and Rancher Desktop**.

- **Browse and copy files out.** Containers appear as folders in the sidebar. Browse their files read-only, fetch contents
  as needed, or open a terminal inside a container.
- **Manage containers in place.** Start, stop, restart or pause them from the context menu or inspector. See their images,
  ports, mounts and Compose services.
- **Control Compose stacks.** Start, stop or restart a project's containers together, and open the project in your terminal
  or code editor.

## Everything else you'd expect, done right

| | |
|---|---|
| **Trash** | In the sidebar, like Finder: Put Back (also what Finder trashed), Delete Immediately and Empty Trash, with other disks' Trashes counted. |
| **Archives** | Compress and extract zip, tar, 7z, rar and more, safely: nothing escapes its folder and downloads stay quarantined. Or double-click a zip to browse it like a folder and copy things out. |
| **Tags** | Finder's tags everywhere: colored dots, the color row in the context menu, a tag field in the inspector, a Tags section in the sidebar and `tag:` in search. |
| **Batch rename** | Replace text (or a regular expression), add text, number with a format or change case, previewed live, undone in one step. |
| **Get Info** | Edit comments, the app a file opens with, Locked and permissions right in the inspector. |
| **Network shares** | Connect to SMB, AFP, NFS and WebDAV shares (⌥⌘K), with macOS's own login and your keychain; SFTP servers and S3 buckets are covered above. |
| **Cloud folders** | See what's only in iCloud Drive or another cloud folder, with Download Now and Remove Download. |
| **Compare and sync** | Compare the two panes' folders and sync them both ways, one way, or as a mirror, verified and undoable. |
| **Your shortcuts, your look** | Change any menu shortcut in Settings. Follow the system appearance or choose Light or Dark. Adjust row density and file name size. |
| **Copy queue** | Big copies run in the background with progress you can pause, resume or cancel. Conflicts are asked up front, with a side-by-side comparison and a diff for text files, and folders can be merged. Turn on **Verify copies** in Settings to check that every byte arrived. Moves between disks keep the original if it changed while copying. |
| **History** | Renames, moves, copies and deletions are recorded. Undo them later, even days later and after a restart, as long as the items are still where they were left. |
| **Recents** | Files you changed in the last 7 days, across your home folder, in one place. |
| **Shelf** | Collect files from anywhere, then drop them all at once. |
| **Your sidebar** | Drag folders into Favorites, reorder them, and eject disks right from the sidebar, or switch it to a tree of every folder. Windows and tabs come back where you left them. |
| **Path bar** | Type a path, `github/acme`, or just a folder's name: matching folders are suggested as you type. |
| **Workspaces** | Save a set of tabs and panes, with their views, and reopen them together from the sidebar, ⌘K or `strata -w`. Folders on network shares and servers connect again. |
| **Ask Strata** | Describe a bulk change (`rename these photos by date taken`) and review the plan before anything happens. Runs on your Mac: built-in rules handle common requests, and Apple Intelligence handles the rest. |
| **Summaries** | Get the gist of a PDF or document in the inspector: a short summary written by Apple Intelligence, or the key sentences without it. Nothing ever leaves your Mac. |
| **Command line** | Install it from Settings, then `strata .` opens the current folder and `strata -s "invoice pdf"` searches from your terminal. |

## Keyboard first

Most actions have a shortcut, and most of the ones you know from Finder work the same way. Can't remember one?
Click **Keyboard Shortcuts** at the bottom of the sidebar, or press ⌘/.

<p align="center"><img src="docs/screenshots/shortcuts.png" alt="The keyboard shortcuts window" width="420"></p>

## Private by design

Strata runs entirely on your Mac. Search, summaries and AI features run locally, with no accounts,
tracking or cloud processing. Strata encrypts operation history on disk with a key kept in your Keychain.
It connects to the servers you add. Containers' and servers' files are read as you browse and cleared
when Strata quits. SFTP logs in with your own SSH setup, and an S3 secret key stays in your keychain.

Read the [Strata app Privacy Policy](https://stratafiles.app/privacy/) for details about local data, storage,
permissions, network connections and your controls.

## Translations

Strata comes in 22 languages and follows your Mac's (or pick one in Settings ▸ General). Each language is one plain
JSON file in [Localization](Localization): improving a translation or adding a language is a pull request, no Xcode
needed. [Localization/README.md](Localization/README.md) has the four steps.

The README translations share this English source and are generated from catalogs. See the
[README translation guide](docs/readme-localization.md) to update one or add another language.

<a id="get-strata"></a>

## Get Strata

Download the latest version from [GitHub Releases](https://github.com/cristipufu/strata-files/releases/latest), open the disk
image and drag Strata to Applications. It needs an Apple silicon Mac running **macOS 26**. Releases are signed and
notarized by Apple, so Strata opens like any other app.

Homebrew:

```sh
brew install --cask cristipufu/tap/strata
```

Or build it yourself with the Swift toolchain (Xcode or the Command Line Tools):

```sh
git clone https://github.com/cristipufu/strata-files.git
cd strata-files
scripts/build.sh release --open
```

For the best experience, give Strata **Full Disk Access** in System Settings ▸ Privacy & Security, so it can search
and measure everything without asking folder by folder. Strata walks you through it on first launch.

## Releasing

Push a version tag and the [Release workflow](.github/workflows/release.yml) builds Strata on a Mac, signs it with the
Developer ID certificate, has Apple notarize it, and publishes a GitHub Release with `Strata.dmg`, `Strata.zip` and
their checksums. The release notes come from `docs/release-notes/<version>.md` when there is one.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

## License

Strata is open source under the [MIT License](LICENSE).

---

<p align="center">
  Found a bug or have an idea? <a href="https://github.com/cristipufu/strata-files/issues">Open an issue</a>.
</p>
