import Testing
@testable import StrataModel

struct FootprintReaderTests {
    @Test func blockCountsAreNonnegativeAndSaturateBeforeMultiplication() {
        #expect(FootprintReader.allocatedBytes(blocks: -1) == 0)
        #expect(FootprintReader.allocatedBytes(blocks: 0) == 0)
        #expect(FootprintReader.allocatedBytes(blocks: 8) == 4096)
        #expect(FootprintReader.allocatedBytes(blocks: Int64.max/512) == Int64.max/512*512)
        #expect(FootprintReader.allocatedBytes(blocks: Int64.max/512+1) == .max)
        #expect(FootprintReader.allocatedBytes(blocks: .max) == .max)
    }
}
