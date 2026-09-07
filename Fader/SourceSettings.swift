import Foundation

struct SourceSettings: Codable, Equatable {
    static let maximumVolume: Float = 1

    var volume: Float = 1
    var muted = false
    var outputUID: String? = nil

    static func clampedVolume(_ value: Float) -> Float {
        value.isFinite ? min(maximumVolume, max(0, value)) : 1
    }
    var gain: Float { muted ? 0 : Self.clampedVolume(volume) }
    var needsMixing: Bool { gain != 1 || outputUID != nil }
}
