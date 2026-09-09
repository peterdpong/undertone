import Foundation

@main struct SourceSettingsTests {
    static func main() throws {
        var settings = SourceSettings()
        precondition(settings.gain == 1 && !settings.needsMixing)
        settings.loudnessEqualization = true
        precondition(settings.needsMixing && settings.gain == 1, "Equalization must run at 100%")
        let equalized = try JSONDecoder().decode(SourceSettings.self, from: JSONEncoder().encode(settings))
        precondition(equalized.loudnessEqualization)
        settings.loudnessEqualization = false
        precondition(!settings.needsMixing, "Turning equalization off at unity should restore bypass")
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
        let nearUnity = SourceSettings(volume: 0.99586153)
        precondition(nearUnity.gain == 1 && !nearUnity.needsMixing, "Displayed 100% must release the tap")
        precondition(SourceSettings.clampedVolume(1.004) == 1)
        precondition(SourceSettings.clampedVolume(0.99) == 0.99)
        precondition(SourceSettings.clampedVolume(1.01) == 1.01)
        for id in ["com.apple.FaceTime", "com.apple.avconferenced", "com.apple.callservicesd"] {
            precondition(AudioMixingPolicy.isProtected(bundleID: id))
            precondition(AudioMixingPolicy.sanitized([id: SourceSettings(volume: 2)]).isEmpty,
                         "Old call preferences must never create taps")
        }
        precondition(AudioMixingPolicy.isProtected(bundleID: "pid.123", executableName: "avconferenced"),
                     "Call helpers must be excluded before parent-app grouping")
        precondition(AudioMixingPolicy.isProtected(bundleID: "some.responsible.app", executableName: "callservicesd"))
        precondition(!AudioMixingPolicy.isProtected(bundleID: "company.thebrowser.Browser", executableName: "Arc Helper"))
        let browser = ["company.thebrowser.Browser": SourceSettings(volume: 2, outputUID: "speakers")]
        precondition(AudioMixingPolicy.sanitized(browser) == browser, "Browser boost and routing must stay available")
        let legacy = Data(#"{"volume":0.5,"muted":false}"#.utf8)
        let old = try JSONDecoder().decode(SourceSettings.self, from: legacy)
        precondition(old.volume == 0.5 && old.needsMixing)
        precondition(!old.loudnessEqualization, "Existing app settings must default equalization off")
        print("PASS: boost, persistence, mute, unity bypass, routing, bounds, legacy settings, call protection")
    }
}
