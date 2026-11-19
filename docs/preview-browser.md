# Quick Look and inspector previews

Space opens the macOS Quick Look panel for the browser selection. The Quick Look menu, command palette and toolbar
use the same panel. For a single selected item, direction keys can move the selection in the source browser;
the system handles navigation among multiple selected items.

Quick Look receives the selected URLs from the pane. Server and container placeholder files are fetched through the
pane's copy providers before the panel opens. A pending open is discarded when its navigation or selection changes.

The inspector uses Strata's format-specific previews and macOS Quick Look for its fallback. Archive browsing through
Open as Folder continues to use the [archive service](archive-sandbox.md).

File thumbnails in the browser come from macOS Quick Look. When Quick Look cannot produce a thumbnail, the browser
shows the file’s icon.

## HTML documents

HTML, HTM and XHTML use an offline WebKit preview with a Preview / Source switch and an explicit Open in Browser
command. Templates such as Vue, Svelte and PHP remain source previews. `WebPreviewView` owns reattachment and
shutdown; `PreviewWebPage` owns one WebKit lifetime. A closed lifetime cannot receive late resources or content.

The renderer uses a nonpersistent data store, disables document JavaScript and blocks network requests independently
of the document's Content Security Policy. Forms, downloads, embedded pages, popups, file pickers and automatic
redirects are refused. WebKit receives a private document scheme rather than file URLs or broad filesystem access.
Local CSS and bounded raster images are read through no-follow descriptors in the selected document's folder.
Provider and archive previews do not fetch surrounding assets automatically.

Input is limited to 512 KiB. Assets allow 32 distinct attempts and 8 MiB in total, including conversion; CSS is limited
to 256 KiB and image input to 4 MiB. Images share a sixteen-million-pixel budget and are reduced to at most 2,048 pixels
on an edge. A WebKit lifetime also limits repeated requests and total response bytes. Unsupported or oversized HTML
uses bounded Source rather than unrestricted Quick Look. A page that has not started displaying within eight seconds
switches to Source; an already displayed page may finish loading its allowed assets.
