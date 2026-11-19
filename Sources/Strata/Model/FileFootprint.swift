nonisolated package enum FootprintReader {
    package static func allocatedBytes(blocks: Int64) -> Int64 {
        let blocks = max(0, blocks)
        return blocks > Int64.max / 512 ? .max : blocks * 512
    }
}
