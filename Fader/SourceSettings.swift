import Foundation

struct SourceSettings: Codable, Equatable {
    static let maximumVolume = FaderMaximumGain

    var volume: Float = 1
    var muted = false
    var outputUID: String? = nil

    static func clampedVolume(_ value: Float) -> Float {
        let clamped = value.isFinite ? min(maximumVolume, max(0, value)) : 1
        // A level displayed as 100% must bypass processing on the default output.
        return abs(clamped - 1) < 0.005 ? 1 : clamped
    }
    var gain: Float { muted ? 0 : Self.clampedVolume(volume) }
    var needsMixing: Bool { gain != 1 || outputUID != nil }
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
