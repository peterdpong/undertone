import Foundation

@main struct SourceSettingsTests {
    static func main() throws {
        var settings = SourceSettings()
        precondition(settings.gain == 1 && !settings.needsMixing)
        settings.volume = 2.5
        precondition(settings.gain == 2.5 && settings.needsMixing, "Boost must activate processing")
        settings.muted = true
        precondition(settings.gain == 0 && settings.volume == 2.5 && settings.needsMixing)
        let data = try JSONEncoder().encode(settings)
        var restored = try JSONDecoder().decode(SourceSettings.self, from: data)
        precondition(restored == settings, "Saved boost and mute must survive relaunch")
        restored.muted = false
        precondition(restored.gain == 2.5, "Unmute must restore boost")
        restored.volume = 1
        precondition(!restored.needsMixing, "100% system output should release processing")
        restored.outputUID = "external-speakers"
        precondition(restored.needsMixing, "Routing still requires processing at unity")
        precondition(SourceSettings.clampedVolume(9) == 4)
        precondition(SourceSettings.clampedVolume(-1) == 0)
        precondition(SourceSettings.clampedVolume(.nan) == 1)
        precondition(SourceSettings.clampedVolume(.infinity) == 1)
        let legacy = Data(#"{"volume":0.5,"muted":false}"#.utf8)
        let old = try JSONDecoder().decode(SourceSettings.self, from: legacy)
        precondition(old.volume == 0.5 && old.needsMixing)
        print("PASS: boost activation, persistence, mute restoration, unity bypass, routing, bounds, legacy settings")
    }
}
