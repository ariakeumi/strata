/// What file views show of an item besides its own attributes: its Finder tags and iCloud status, each
/// read off the main thread by the window's store and shown once read.
struct FileStatuses {
    let tags: TagStore
    let cloud: CloudStore
}
