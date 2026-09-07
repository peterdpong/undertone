import Foundation

struct PresetDevice: Codable, Equatable {
    var uid: String
    var name: String
    var volume: Float?
}

struct MixSnapshot: Codable, Equatable {
    var apps: [String: SourceSettings]
    var names: [String: String]
    var output: PresetDevice?
    var input: PresetDevice?

    init(settings: [String: SourceSettings], names: [String: String], output: PresetDevice?, input: PresetDevice?) {
        // Process IDs are recycled; only app identities can safely survive a relaunch.
        let savedApps = settings.filter { !$0.key.hasPrefix("pid.") }.mapValues {
            var value = $0
            value.volume = SourceSettings.clampedVolume(value.volume)
            return value
        }
        apps = savedApps
        self.names = names.filter { savedApps[$0.key] != nil }
        self.output = output
        self.input = input
    }

    func matches(_ other: MixSnapshot) -> Bool {
        // Explicit defaults and apps that have never been adjusted mean the same thing.
        let adjusted = apps.filter { $0.value != SourceSettings() }
        let otherAdjusted = other.apps.filter { $0.value != SourceSettings() }
        return adjusted == otherAdjusted && Self.matches(output, other.output) && Self.matches(input, other.input)
    }

    private static func matches(_ lhs: PresetDevice?, _ rhs: PresetDevice?) -> Bool {
        guard lhs?.uid == rhs?.uid else { return false }
        switch (lhs?.volume, rhs?.volume) {
        case let (a?, b?): return abs(a - b) < 0.005 // Hardware volume can be quantized.
        case (nil, nil): return true
        default: return false
        }
    }
}

struct MixPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var mix: MixSnapshot
}

struct PresetLibrary {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [MixPreset] {
        guard let data = defaults.data(forKey: "mixPresets") else { return [] }
        return (try? JSONDecoder().decode([MixPreset].self, from: data)) ?? []
    }

    func save(_ presets: [MixPreset]) {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "mixPresets") }
    }
}
