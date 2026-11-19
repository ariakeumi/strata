/// Comic aliases stay archives. EPUB packages supply a reading order and a declared cover instead.
nonisolated package enum BookFormat {
    package static let books: Set<String> = ["epub", "mobi", "azw", "azw3", "djvu", "djv", "fb2"]
    package static let comics: Set<String> = ["cbz", "cbr", "cb7", "cbt"]
    package static let images: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif", "heic", "heif", "tif", "tiff", "bmp"]
}
