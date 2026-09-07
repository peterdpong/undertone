import Foundation

@main struct PresetTests {
    static func main() throws {
        let suite = "FaderPresetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = PresetLibrary(defaults: defaults)
        precondition(library.load().isEmpty)
        var live = ["com.browser": SourceSettings(volume: 2, muted: false, outputUID: "headphones"),
                    "com.music": SourceSettings(volume: 0.5, muted: true),
                    "pid.123": SourceSettings(volume: 3)]
        let output = PresetDevice(uid: "speakers", name: "Speakers", volume: 0.68)
        let snapshot = MixSnapshot(settings: live, names: ["com.browser": "Browser", "pid.123": "Helper"], output: output, input: nil)
        precondition(snapshot.apps["pid.123"] == nil && snapshot.names["pid.123"] == nil)
        live["com.browser"]?.volume = 1
        precondition(snapshot.apps["com.browser"]?.volume == 2, "Snapshot must remain independent of current edits")
        let preset = MixPreset(name: "FaceTime", mix: snapshot)
        library.save([preset])
        let restored = PresetLibrary(defaults: defaults).load()
        precondition(restored == [preset], "Names, identities, boosts, mute, routes and devices must survive relaunch")
        precondition(restored[0].mix.apps["com.browser"]?.gain == 2, "Inactive app boost must be retained by stable identity")
        var equivalent = snapshot
        equivalent.apps["com.newapp"] = SourceSettings()
        equivalent.names["com.browser"] = "Renamed Browser"
        equivalent.output?.volume = 0.681
        precondition(snapshot.matches(equivalent), "Default apps, display names and hardware quantization should not mark a preset changed")
        equivalent.apps["com.browser"]?.volume = 2.5
        precondition(!snapshot.matches(equivalent), "Manual level changes must uncheck the current preset")
        equivalent = snapshot
        equivalent.output?.uid = "other-speakers"
        precondition(!snapshot.matches(equivalent), "Device changes must uncheck the current preset")
        var renamed = preset
        renamed.name = "Calls"
        library.save([renamed])
        precondition(library.load()[0].id == preset.id && library.load()[0].name == "Calls")
        library.save([])
        precondition(library.load().isEmpty, "Deletion must survive relaunch")
        var legacyCallPreset = preset
        legacyCallPreset.mix.apps["com.apple.avconferenced"] = SourceSettings(volume: 0.99586153)
        legacyCallPreset.mix.apps["com.apple.FaceTime"] = SourceSettings(volume: 4, outputUID: "headphones")
        legacyCallPreset.mix.names["com.apple.avconferenced"] = "Call helper"
        library.save([legacyCallPreset])
        let migrated = library.load()[0]
        precondition(migrated.mix.apps["com.apple.avconferenced"] == nil && migrated.mix.apps["com.apple.FaceTime"] == nil,
                     "Loading an old preset must remove call levels and routes")
        precondition(migrated.mix.names["com.apple.avconferenced"] == nil)
        precondition(migrated.mix.apps["com.browser"]?.volume == 2, "Migration must preserve browser boost")
        precondition(migrated.mix.matches(legacyCallPreset.mix), "Protected call entries must not affect preset matching")
        precondition(library.load()[0] == migrated, "Migration must persist")
        precondition(AudioMixingPolicy.sanitized(legacyCallPreset.mix.apps) == migrated.mix.apps,
                     "Applying an unmigrated preset must use the same call protection")
        defaults.set(Data("invalid".utf8), forKey: "mixPresets")
        precondition(library.load().isEmpty, "Invalid data must not crash startup")
        print("PASS: preset snapshots, identity, persistence, matching, rename, deletion, call migration, invalid data")
    }
}
