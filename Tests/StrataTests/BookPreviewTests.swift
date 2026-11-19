@testable import StrataArchives
import AppKit
import ImageIO
import WebKit
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch
@testable import StrataPreviews

@Suite(.archiveWorkerApp)
struct BookPreviewTests {
    private func image(_ width: Int = 12, _ height: Int = 24) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData(), target = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(target))
        return data as Data
    }
    /// Stored ZIP fixtures exercise the real sandboxed worker, without invoking tools on the main thread.
    private func epub(_ tree: TestTree, legacy: Bool = false, chapterTitle: String = "First chapter", navigationHeader: String = "", secondChapterTitle: String = "Second chapter", openingPage: String? = nil, guideCover: Bool = false) throws -> URL {
        let container = #"<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="Book/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#
        let metadata = legacy ? #"<meta name="cover" content="cover"/>"# : ""
        let property = legacy ? "" : #"properties="cover-image""#
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>A &amp; B</dc:title><dc:creator>Ana</dc:creator><dc:creator>Ion</dc:creator><dc:publisher>Acme</dc:publisher><dc:language>ro</dc:language>\(metadata)</metadata>
        <manifest><item id="other" href="Images/first.png" media-type="image/png"/>
        <item id="cover" href="Images/cover%20art.png" media-type="image/png" \(property)/>
        <item id="two" href="Text/02.xhtml" media-type="application/xhtml+xml"/>
        <item id="one" href="Text/01.xhtml" media-type="application/xhtml+xml"/>
        \(openingPage == nil ? "" : #"<item id="opening" href="Text/wrap0000.xhtml" media-type="application/xhtml+xml"/>"#)
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="style" href="Styles/book.css" media-type="text/css"/></manifest>
        <spine>\(openingPage == nil ? "" : #"<itemref idref="opening"/>"#)<itemref idref="one"/><itemref idref="two"/></spine>
        \(guideCover ? #"<guide><reference type="cover" href="Text/wrap0000.xhtml"/></guide>"# : "")</package>
        """
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", Data(container.utf8)),
            ("Book/package.opf", Data(package.utf8)), ("Book/Images/first.png", try image(32, 8)),
            ("Book/Images/cover art.png", try image()), ("Book/Text/01.xhtml", Data(#"<h1>First</h1><link rel="stylesheet" href="../Styles/book.css"><img src="../Images/cover%20art.png"><script>bad()</script>"#.utf8)),
            ("Book/Text/02.xhtml", Data("<h1>Second</h1>".utf8)), ("Book/Styles/book.css", Data("h1 { color: navy }".utf8)),
            ("Book/nav.xhtml", Data((navigationHeader + #"<html xmlns="http://www.w3.org/1999/xhtml"><nav><a href="Text/01.xhtml">\#(chapterTitle)</a><a href="Text/02.xhtml">\#(secondChapterTitle)</a></nav></html>"#).utf8)),
            ("secret.txt", Data("not a resource".utf8)),
        ]
        if let openingPage { entries.append(("Book/Text/wrap0000.xhtml", Data(openingPage.utf8))) }
        let url = tree.url("book.epub"); try StoredZIP.make(entries).write(to: url); return url
    }

    @Test func epubMetadataSpineAndOfflineResourcesUseTheRealWorker() async throws {
        for legacy in [false, true] {
            let tree = try TestTree("book.epub", "outside/keep")
            let url = try epub(tree, legacy: legacy), before = tree.snapshot()
            let book = try await EPUBBook.open(FileReadSource(url))
            #expect(book.title == "A & B" && book.authors == "Ana, Ion" && book.publisher == "Acme" && book.language == "ro")
            #expect(book.chapters.map(\.title) == ["First chapter", "Second chapter"])
            #expect(book.chapters.map(\.path) == [["Book", "Text", "01.xhtml"], ["Book", "Text", "02.xhtml"]])
            let document = try EPUBChapterDocument(book: book, chapter: 0)
            let page = try await document.read(document.url)
            let html = String(decoding: page.data, as: UTF8.self)
            #expect(page.mime.hasPrefix("text/html") && html.contains("<h1>First</h1>") && html.contains("script-src 'none'"))
            let css = try #require(URL(string: "../Styles/book.css", relativeTo: document.url)?.absoluteURL)
            #expect(try await document.read(css).mime.hasPrefix("text/css"))
            let image = try #require(URL(string: "../Images/cover%20art.png", relativeTo: document.url)?.absoluteURL)
            #expect(try await document.read(image).mime == "image/png")
            for ref in ["https://fixture.invalid/image.png", "file:///etc/passwd", "../../../secret.txt", "strata-html://other/Book/Images/cover%20art.png"] {
                let request = try #require(URL(string: ref, relativeTo: document.url)?.absoluteURL)
                await #expect(throws: (any Error).self) { try await document.read(request) }
            }
            #expect(tree.snapshot() == before && tree.text("outside/keep") == "outside/keep")
        }
    }

    @Test func comicAliasesKeepTheirArchivePreviews() {
        for ext in ["CBZ", "cbr", "cb7", "cbt"] {
            #expect(ArchiveKind(fileName: "book.\(ext)") != nil)
            guard case .archive = PreviewFormat(url: URL(fileURLWithPath: "book.\(ext)"), contentType: nil) else { Issue.record("Comic lost its archive preview"); continue }
        }
    }

    @Test func coverWrappersAndUntitledSectionsNeverExposeInternalFilenames() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let wrapper = #"<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head><body><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../Images/cover%20art.png"/></svg></body></html>"#
        for (opening, guide, expected) in [
            (wrapper, false, String(localized: "Cover")),
            (#"<html><body><img src="../Images/cover%20art.png"/><p>Opening text</p></body></html>"#, false, String(localized: "Section \(1)")),
            (#"<html><body><img src="../Images/first.png"/></body></html>"#, false, String(localized: "Section \(1)")),
            ("<html><body>Illustrated cover</body></html>", true, String(localized: "Cover")),
        ] {
            let book = try await EPUBBook.open(FileReadSource(epub(tree, openingPage: opening, guideCover: guide)))
            #expect(book.chapters.map(\.title) == [expected, "First chapter", "Second chapter"])
        }
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func packageReferencesAndXMLAreBoundedBeforeParsingOrOpeningMembers() throws {
        for href in ["../../escape", "/absolute", "https://fixture.invalid/a", "//host/a", "a%2fb", "%2e%2e/escape", "a%00b", "a\\b", "a?query"] {
            #expect(throws: (any Error).self) { try EPUBBook.path(href, relativeTo: []) }
        }
        #expect(try EPUBBook.path("../Images/cover%20art.png#cover", relativeTo: ["Book", "Text"]) == ["Book", "Images", "cover art.png"])
        for xml in [#"<!DOCTYPE package [<!ENTITY x "expanded">]><package>&x;</package>"#, "<a>" + String(repeating: "<a>", count: 64) + String(repeating: "</a>", count: 65), "<broken>", String(repeating: "x", count: TextFile.limit + 1)] {
            #expect(throws: (any Error).self) { try BookXML.parse(Data(xml.utf8)) }
        }
        #expect(try BookXML.parse(Data("<package><title>Café 漫画</title></package>".utf8)).children.first?.text == "Café 漫画")
        #expect(throws: PreviewError.self) { try PreviewPicture(Data("not an image".utf8)) }
    }

    @Test func ordinaryNavigationDoctypesPreserveTheBooksChapterTitles() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let url = try epub(tree, navigationHeader: "<!DOCTYPE html>\n")
        let book = try await EPUBBook.open(FileReadSource(url))
        #expect(book.chapters.map(\.title) == ["First chapter", "Second chapter"])
        let ncx = #"<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://fixture.invalid/toc.dtd"><ncx><navMap><navPoint><navLabel><text>Part One</text></navLabel></navPoint></navMap></ncx>"#
        #expect(try BookXML.parse(Data(ncx.utf8)).descendants("navLabel").first?.allText == "Part One")
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func nestedXMLLabelsAndLargeMetadataKeepTextExactlyOnce() throws {
        let description = String(repeating: "A long description. ", count: 500)
        let xml = "<package><metadata><description>\(description)</description>\n</metadata>\n<nav><a href='one'><span>Chapter <b><i>One</i></b></span></a>\n<a href='two'>Chapter Two</a>\n</nav>\n</package>"
        let root = try BookXML.parse(Data(xml.utf8))
        #expect(root.descendants("a").map(\.allText) == ["Chapter One", "Chapter Two"])
        #expect(root.descendants("description").first?.allText == description)
    }

    @Test func chapterTitlesBoundCombiningSequencesBeforeBuildingNativeMenus() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let title = "A" + String(repeating: "\u{301}", count: 2000)
        let url = try epub(tree, chapterTitle: title)
        let book = try await EPUBBook.open(FileReadSource(url))
        let header = PreviewContentsHeader(name: "book")
        header.show(book)
        let displayed = try #require(header.contents.itemTitles.first)
        #expect(!displayed.isEmpty && displayed.utf8.count <= 1200)
        #expect(!displayed.contains("\u{fffd}"))
        #expect(tree.snapshot() == ["book.epub", "sibling"] && tree.text("sibling") == "sibling")
    }

    @Test func nativeContentsKeepsDuplicateTitlesAndTheirSpinePositions() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let book = try await EPUBBook.open(FileReadSource(epub(tree, chapterTitle: "Notes", secondChapterTitle: "Notes")))
        let header = PreviewContentsHeader(name: "book")
        header.frame = NSRect(x: 0, y: 0, width: 280, height: 88)
        header.show(book); header.layoutSubtreeIfNeeded()
        #expect(header.contents.itemTitles == ["Notes", "Notes"])
        #expect(header.contents.itemArray.map(\.tag) == [0, 1])
        var choices: [Int] = []
        header.onSelect = { choices.append($0) }
        header.contents.menu?.performActionForItem(at: 1)
        #expect(choices == [1])
        #expect(header.selected == 1 && header.contents.selectedItem?.tag == 1)
        #expect(header.position.stringValue == "2 / 2")
        #expect(header.navigation.isEnabled(forSegment: 0) && !header.navigation.isEnabled(forSegment: 1))
        #expect(header.frame.contains(header.convert(header.navigation.bounds, from: header.navigation)))
        #expect(header.title.stringValue == "A & B" && header.subtitle.stringValue == "Ana, Ion")
        for width in [280.0, 1000.0] {
            header.setFrameSize(NSSize(width: width, height: 88)); header.layoutSubtreeIfNeeded()
            let title = header.convert(header.title.bounds, from: header.title)
            let author = header.convert(header.subtitle.bounds, from: header.subtitle)
            #expect((10...16).contains(title.minX) && abs(author.minX - title.minX) < 1)
            #expect(title.maxX <= width - 12 && author.maxX <= width - 12)
        }
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func documentDeclarationsNeverPermitInternalSubsetsOrEntityExpansion() throws {
        for xml in ["<!DOCTYPE html []><html/>", "<!DOCTYPE html [<!ELEMENT html ANY>]><html/>",
                    #"<!DOCTYPE html [<!ENTITY x "expanded">]><html>&x;</html>"#,
                    "<!DOCTYPE html><!DOCTYPE html><html/>", "<!DOCTYPE html SYSTEM 'unterminated><html/>"] {
            #expect(throws: (any Error).self) { try BookXML.parse(Data(xml.utf8)) }
        }
        #expect(try BookXML.parse(Data("<!DOCTYPE html SYSTEM 'http://fixture.invalid/ignored.dtd'><html>Safe</html>".utf8)).allText == "Safe")
    }

    @Test func duplicateChapterAssetsShareOneReadAndOneCancellationKeepsTheOtherReader() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let book = try await EPUBBook.open(FileReadSource(epub(tree)))
        let (events, signal) = AsyncStream<Int>.makeStream()
        let gate = EPUBResourceReadGate(started: signal)
        let document = try EPUBChapterDocument(book: book, chapter: 0, reader: { _, _, _, _ in try await gate.read() })
        let url = try #require(URL(string: "../Styles/book.css", relativeTo: document.url)?.absoluteURL)
        let first = Task.detached { try await document.read(url) }
        var started = events.makeAsyncIterator(); #expect(await started.next() == 0)
        let second = Task.detached { try await document.read(url) }
        defer { first.cancel(); second.cancel(); signal.finish() }
        try await document.waitForSharedReaders()
        first.cancel()
        await gate.finish(0, Data("h1 { color: navy }".utf8))
        let resource = try await second.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(resource.mime.hasPrefix("text/css"))
        #expect(try await document.read(url).data == resource.data)
        #expect(await gate.readCount == 1)
        #expect(await gate.cancellations == 0)
        #expect(await document.pendingWaiterCount == 0)
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func cancellingAllChapterAssetReadersCancelsTheirSharedWork() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let book = try await EPUBBook.open(FileReadSource(epub(tree)))
        let (events, signal) = AsyncStream<Int>.makeStream()
        let gate = EPUBResourceReadGate(started: signal)
        let document = try EPUBChapterDocument(book: book, chapter: 0, reader: { _, _, _, _ in try await gate.read() })
        let first = Task.detached { try await document.read(document.url) }
        var started = events.makeAsyncIterator(); #expect(await started.next() == 0)
        let second = Task.detached { try await document.read(document.url) }
        defer { first.cancel(); second.cancel(); signal.finish() }
        try await document.waitForSharedReaders()
        first.cancel(); second.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await gate.cancellations == 1)
        #expect(await document.pendingWaiterCount == 0)
        let retry = Task.detached { try await document.read(document.url) }
        #expect(await started.next() == 1)
        await gate.finish(1, Data("<h1>Retried</h1>".utf8))
        #expect(try await retry.value.mime.hasPrefix("text/html"))
        signal.finish()
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func reattachingDuringTheInitialBookReadRestartsItAndRejectsItsOldCompletion() async throws {
        let tree = try TestTree("book.epub", "sibling")
        let url = try epub(tree), book = try await EPUBBook.open(FileReadSource(url))
        let (events, signal) = AsyncStream<Int>.makeStream()
        let gate = EPUBBookLoadGate(started: signal)
        let view = EPUBPreviewView(url: url, loader: { _ in try await gate.read() },
                                   timeLimit: PreviewWebPage.noTimeLimit)
        _ = NSApplication.shared
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; return window
        }
        let first = window(), second = window(); first.contentView = view
        let old = try #require(view.loadingTask)
        var started = events.makeAsyncIterator(); #expect(await started.next() == 0)
        first.contentView = nil; second.contentView = view
        #expect(view.loadingTask != nil, "Reattachment must start a new book load before waiting for it")
        guard view.loadingTask != nil else {
            await gate.finish(0, book); await old.value
            first.close(); second.close(); signal.finish()
            #expect(tree.snapshot() == ["book.epub", "sibling"])
            return
        }
        #expect(await started.next() == 1)
        await gate.finish(1, book)
        await view.loadingTask?.value; await view.page.task?.value
        view.forward(); await view.page.task?.value
        #expect(view.header.selected == 1)
        await gate.finish(0, book); await old.value
        #expect(view.header.selected == 1 && view.webView != nil)
        first.close()
        #expect(view.webView != nil)
        second.close(); signal.finish()
        #expect(view.webView == nil)
        #expect(tree.snapshot() == ["book.epub", "sibling"])
    }

    @Test func epubSourceReplacementAndOversizedMembersAreRefused() async throws {
        let tree = try TestTree("book.epub", "replacement", "outside/keep")
        let url = try epub(tree), source = try FileReadSource(url)
        let book = try await EPUBBook.open(source)
        let oversized = [ArchiveRecord(path: ["big"], kind: 1, size: Int64(TextFile.limit + 1), modified: .distantPast, body: nil)]
        await #expect(throws: (any Error).self) { try await EPUBBook.bytes(source, records: oversized, path: ["big"], limit: TextFile.limit) }
        try FileManager.default.moveItem(at: url, to: tree.url("original.epub"))
        try FileManager.default.moveItem(at: tree.url("replacement"), to: url)
        let before = tree.snapshot()
        let document = try EPUBChapterDocument(book: book, chapter: 0)
        await #expect(throws: (any Error).self) { try await document.read(document.url) }
        #expect(tree.text("book.epub") == "replacement" && tree.snapshot() == before)
    }

    @Test func epubThumbnailRequestFinishesWhenQuickLookHasNoThumbnail() async throws {
        let tree = try TestTree("book.epub", "outside/keep")
        let url = try epub(tree), entry = try #require(FileEntry(url: url))
        var requests = 0
        let thumbnails = FileThumbnails(copies: .live, containerStore: .shared, generate: { request, completion in
            requests += 1
            #expect(request.representationTypes == .thumbnail)
            completion(nil, false)
        })
        #expect(thumbnails.canThumbnail(entry))
        let image: NSImage? = await withCheckedContinuation { continuation in
            var result: NSImage?
            thumbnails.request(entry, size: 64, scale: 1, finished: { continuation.resume(returning: result) }) { result = $0 }
        }
        #expect(requests == 1 && image == nil)
        #expect(thumbnails.cached(entry, size: 64, scale: 1) == nil)
        #expect(thumbnails.hasFailed(entry, size: 64, scale: 1))
        #expect(tree.text("outside/keep") == "outside/keep")
    }

    @Test func bookAndComicKindsAgreeAcrossIndexFiltersAndSpotlightAuthors() throws {
        for alias in ["book", "books", "ebook", "ebooks"] { #expect(SearchQuery.parse("kind:\(alias)").kind == .book) }
        #expect(SearchQuery.parse("kind:comic").kind == .comic)
        #expect(QueryInterpreter.parse("comic books").filter.kinds == [.comic])
        #expect(QueryInterpreter.parse("ebooks").filter.kinds == [.book])
        for ext in ["epub", "mobi", "azw3", "djvu"] { #expect(SearchFilter.Kind.book.matches(type: nil, isDirectory: false, isPackage: false, extension: ext)) }
        for ext in ["cbz", "cbr", "cb7", "cbt"] { #expect(SearchFilter.Kind.comic.matches(type: nil, isDirectory: false, isPackage: false, extension: ext)) }
        #expect(!SearchFilter.Kind.book.matches(type: nil, isDirectory: true, isPackage: false, extension: "epub"))
        let query = SpotlightQuery.parse("kind:book author:Asimov")
        let predicate = try #require(query?.predicate)
        #expect(predicate.evaluate(with: ["kMDItemFSName": "Foundation.epub", "kMDItemAuthors": ["Isaac Asimov"]]))
        #expect(!predicate.evaluate(with: ["kMDItemFSName": "Foundation.pdf", "kMDItemAuthors": ["Isaac Asimov"]]))
    }

    @Test func epubUsesARichPreviewAndClosesItsWebSession() async throws {
        let tree = try TestTree("book.epub", "outside/keep")
        let url = try epub(tree)
        #expect(RichPreview.makeView(for: url, contentType: .epub, preferences: try Prefs.isolated(), clipboard: Clipboard(pasteboard: .withUniqueName(), notifications: NotificationCenter())) is EPUBPreviewView)
        let view = EPUBPreviewView(url: url, timeLimit: PreviewWebPage.noTimeLimit)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        await view.loadingTask?.value
        await view.page.task?.value
        #expect(view.book?.title == "A & B" && view.header.contents.numberOfItems == 2)
        #expect(!view.header.navigation.isEnabled(forSegment: 0) && view.header.navigation.isEnabled(forSegment: 1))
        let web = try #require(view.webView)
        #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        #expect(!web.configuration.websiteDataStore.isPersistent)
        view.forward(); await view.page.task?.value
        #expect(view.header.contents.indexOfSelectedItem == 1 && view.header.navigation.isEnabled(forSegment: 0))
        #expect(!view.header.navigation.isEnabled(forSegment: 1))
        window.close()
        #expect(view.webView == nil && view.page.task == nil)
        #expect(tree.text("outside/keep") == "outside/keep")
    }

}

private extension EPUBChapterDocument {
    func waitForSharedReaders() async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while pendingWaiterCount != 2 {
            try #require(ContinuousClock.now < deadline, "Both readers must join the same pending resource")
            await Task.yield()
        }
    }
}

private actor EPUBResourceReadGate {
    let started: AsyncStream<Int>.Continuation
    private(set) var readCount = 0
    private(set) var cancellations = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    init(started: AsyncStream<Int>.Continuation) { self.started = started }
    func read() async throws -> Data {
        let id = readCount; readCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0; started.yield(id) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancellations += 1; continuation.resume(throwing: CancellationError())
    }
    func finish(_ id: Int, _ data: Data) { pending.removeValue(forKey: id)?.resume(returning: data) }
}

private actor EPUBBookLoadGate {
    let started: AsyncStream<Int>.Continuation
    private var count = 0
    private var pending: [Int: CheckedContinuation<EPUBBook, Error>] = [:]
    init(started: AsyncStream<Int>.Continuation) { self.started = started }
    func read() async throws -> EPUBBook {
        let id = count; count += 1
        return try await withCheckedThrowingContinuation { pending[id] = $0; started.yield(id) }
    }
    func finish(_ id: Int, _ book: EPUBBook) { pending.removeValue(forKey: id)?.resume(returning: book) }
}
