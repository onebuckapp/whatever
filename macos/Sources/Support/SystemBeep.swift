import AppKit

/// Invalid-action feedback. (`NSBeep` is not visible to Swift in this
/// SDK, so the system alert sound is played directly.)
enum SystemBeep {
    static func play() {
        NSSound(named: "Funk")?.play()
    }
}
