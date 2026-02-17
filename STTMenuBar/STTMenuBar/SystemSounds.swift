import Foundation
import AudioToolbox

final class SystemSoundPlayer {
    private var soundOn: SystemSoundID = 0
    private var soundOff: SystemSoundID = 0

    init() {
        soundOn = loadSystemSound(named: "begin_record")
        soundOff = loadSystemSound(named: "end_record")
    }

    deinit {
        AudioServicesDisposeSystemSoundID(soundOn)
        AudioServicesDisposeSystemSoundID(soundOff)
    }

    func playOn() {
        AudioServicesPlaySystemSound(soundOn)
    }

    func playOff() {
        AudioServicesPlaySystemSound(soundOff)
    }

    private func loadSystemSound(named name: String) -> SystemSoundID {
        let base = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system"
        let url = URL(fileURLWithPath: base).appendingPathComponent("\(name).caf")
        var soundID: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        return soundID
    }
}
