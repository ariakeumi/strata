import AudioToolbox
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct SoundsTests {
    @Test func aTestProcessPlaysNoSound() {
        // Only the app's executable turns sounds on: tests refuse and trash things all the time.
        #expect(!Sounds.areOn)
    }

    @Test func theTrashSoundsFollowTheSystemsSettingForInterfaceSounds() throws {
        // Loading one plays nothing.
        for sound in Sounds.TrashSound.allCases {
            var id = try #require(Sounds.load(sound), "\(sound.rawValue)")
            defer { AudioServicesDisposeSystemSoundID(id) }
            var isInterfaceSound: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            let read = AudioServicesGetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size), &id,
                                                &size, &isInterfaceSound)
            #expect(read == noErr && isInterfaceSound == 1, "\(sound.rawValue)")
        }
    }
}
