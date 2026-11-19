import AppKit
import AudioToolbox

/// Every sound Strata plays. They stay silent until the executable turns them on, so tests, which refuse and trash
/// things all the time, play none.
package enum Sounds {
    package enum TrashSound: String, CaseIterable {
        // Finder uses the Dock's short sound when it moves a file to the Trash.
        case moved = "dock/drag to trash"
        case emptied = "finder/empty trash"
    }

    package private(set) static var areOn = false
    private static var loaded: [TrashSound: SystemSoundID] = [:]

    package static func useApplicationSounds() {
        areOn = true
    }

    package static func beep() {
        if areOn { NSSound.beep() }
    }

    package static func movedToTrash() {
        play(.moved)
    }

    package static func emptiedTrash() {
        play(.emptied)
    }

    /// The system's sound server plays it as a sound of the interface, so it's silent when "Play user interface sound
    /// effects" is off, as Finder's own are. A sound is loaded only once sounds are on, and loaded again next time when
    /// that failed.
    private static func play(_ sound: TrashSound) {
        guard areOn else { return }
        if loaded[sound] == nil { loaded[sound] = load(sound) }
        if let id = loaded[sound] { AudioServicesPlaySystemSound(id) }
    }

    package static func load(_ sound: TrashSound) -> SystemSoundID? {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/\(sound.rawValue).aif"
        var id: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == noErr ? id : nil
    }
}
