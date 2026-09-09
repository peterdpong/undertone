import Foundation

struct SourceSettings: Codable, Equatable {
    static let maximumVolume = FaderMaximumGain

    var volume: Float = 1
    var muted = false
    var outputUID: String? = nil
    var loudnessEqualization = false

    init(volume: Float = 1, muted: Bool = false, outputUID: String? = nil, loudnessEqualization: Bool = false) {
        self.volume = volume
        self.muted = muted
        self.outputUID = outputUID
        self.loudnessEqualization = loudnessEqualization
    }

    private enum CodingKeys: String, CodingKey { case volume, muted, outputUID, loudnessEqualization }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        volume = try values.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        outputUID = try values.decodeIfPresent(String.self, forKey: .outputUID)
        loudnessEqualization = try values.decodeIfPresent(Bool.self, forKey: .loudnessEqualization) ?? false
    }

    static func clampedVolume(_ value: Float) -> Float {
        let clamped = value.isFinite ? min(maximumVolume, max(0, value)) : 1
        // A level displayed as 100% must bypass processing on the default output.
        return abs(clamped - 1) < 0.005 ? 1 : clamped
    }
    var gain: Float { muted ? 0 : Self.clampedVolume(volume) }
    var needsMixing: Bool { gain != 1 || outputUID != nil || loudnessEqualization }
}

enum AudioMixingPolicy {
    static func isProtected(bundleID: String, executableName: String? = nil) -> Bool {
        let id = bundleID.lowercased()
        let process = executableName?.lowercased()
        return id == "com.apple.facetime" || id == "com.apple.avconferenced"
            || id == "com.apple.callservicesd" || process == "facetime"
            || process == "avconferenced" || process == "callservicesd"
    }

    static func sanitized(_ settings: [String: SourceSettings]) -> [String: SourceSettings] {
        settings.filter { !isProtected(bundleID: $0.key) }.mapValues {
            var value = $0
            value.volume = SourceSettings.clampedVolume(value.volume)
            return value
        }
    }
}
