import AppKit
import Darwin

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return info.phys_footprint
}

func thumbnail(seed: Int) -> NSImage {
    let side = 1024
    let backing = UnsafeMutableRawPointer.allocate(byteCount: side * side * 4, alignment: 16)
    let pixels = backing.bindMemory(to: UInt32.self, capacity: side * side)
    var value = UInt32(seed + 1)
    for pixel in 0..<(side * side) {
        value ^= value << 13
        value ^= value >> 17
        value ^= value << 5
        pixels[pixel] = value | 0xff00_0000
    }
    let provider = CGDataProvider(dataInfo: nil, data: backing, size: side * side * 4) { _, data, _ in
        UnsafeMutableRawPointer(mutating: data).deallocate()
    }!
    let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    return NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
}

@main struct MemoryBenchmark {
    static func main() {
        let mode = CommandLine.arguments.dropFirst().first ?? "thumbnails"
        let count = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 160
        precondition((1...200_000).contains(count))
        switch mode {
        case "thumbnails", "thumbnails-baseline":
            let image: (String) -> NSImage?
            let insert: (NSImage, String, Int) -> Void
            if mode == "thumbnails-baseline" {
                let cache = ThumbnailCacheBaseline()
                image = cache.image(forKey:)
                insert = { cache.insert($0, forKey: $1, cost: $2) }
            } else {
                let cache = ThumbnailCache()
                image = cache.image(forKey:)
                insert = { cache.insert($0, forKey: $1, cost: $2) }
            }
            let before = footprint()
            let start = ContinuousClock.now
            for number in 0..<count {
                autoreleasepool {
                    insert(thumbnail(seed: number), "thumbnail-\(number)", 1024 * 1024 * 4)
                }
            }
            let elapsed = start.duration(to: .now)
            let loaded = footprint()
            let retained = (0..<count).filter { image("thumbnail-\($0)") != nil }.count
            precondition(image("thumbnail-\(count - 1)")?.size == NSSize(width: 512, height: 512))
            print("\(mode) generated=\(count) retained=\(retained) before_bytes=\(before) loaded_bytes=\(loaded) delta_bytes=\(Int64(loaded) - Int64(before)) fill_time=\(elapsed)")
            withExtendedLifetime((image, insert)) {}
        default:
            fatalError("Expected thumbnails or thumbnails-baseline")
        }
    }
}
