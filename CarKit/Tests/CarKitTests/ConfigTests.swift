import Foundation
import Testing
@testable import CarKit

@Suite struct ConfigTests {
    static let lav = Config.Microphone(uid: "lav", name: "Lav")
    static let cam = Config.Microphone(uid: "cam", name: "Webcam")
    static let list = [lav, cam]

    @Test func theFirstConnectedMicrophoneOnTheListIsUsed() {
        #expect(Config.microphone(from: Self.list, connected: ["lav", "cam", "built-in"], silent: []) == Self.lav)
        // The lav unplugged: the next one down, not the system default.
        #expect(Config.microphone(from: Self.list, connected: ["cam", "built-in"], silent: []) == Self.cam)
        // Plugged back in: back to the top.
        #expect(Config.microphone(from: Self.list, connected: ["lav", "cam"], silent: []) == Self.lav)
        // None of them: the system default.
        #expect(Config.microphone(from: Self.list, connected: ["built-in"], silent: []) == nil)
        #expect(Config.microphone(from: [], connected: ["lav"], silent: []) == nil)
    }

    @Test func aSilentMicrophoneIsPassedOver() {
        #expect(Config.microphone(from: Self.list, connected: ["lav", "cam"], silent: ["lav"]) == Self.cam)
        #expect(Config.microphone(from: Self.list, connected: ["lav", "cam"], silent: ["lav", "cam"]) == nil)
    }

    @Test func settingsSurviveASaveAndAConfigFromBefore() throws {
        var c = Config()
        c.microphones = Self.list
        c.soundQuality = .high
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back.microphones == Self.list && back.soundQuality == .high)

        // A config written before either existed loads with their defaults.
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"remoteModel": "m", "inputUID": "x"}"#.utf8))
        #expect(old.remoteModel == "m" && old.microphones.isEmpty && old.soundQuality == .low)
    }
}
