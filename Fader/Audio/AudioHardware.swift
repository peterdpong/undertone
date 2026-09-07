import AppKit
import CoreAudio

struct AudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? { "\(operation) failed (Core Audio \(status))." }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioFailure(operation: operation, status: status) }
    }
    static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, default value: T) throws -> T {
        var address = address, value = value
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) {
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0), "Reading audio property")
        }
        return value
    }
    static func ids(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Reading audio list size")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try result.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!), "Reading audio list")
        }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        (try? read(object, address(selector), default: "" as CFString)) as String?
    }
    static func write<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address, value = value
        try withUnsafePointer(to: &value) {
            try check(AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0), "Changing audio setting")
        }
    }
    static func writable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address, result = DarwinBoolean(false)
        return AudioObjectHasProperty(object, &address) &&
            AudioObjectIsPropertySettable(object, &address, &result) == noErr && result.boolValue
    }
    static func channels(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + $1.mNumberChannels }
    }
    static func defaultDevice(input: Bool) -> AudioObjectID {
        (try? read(system, address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))) ?? 0
    }
}

final class AudioObservation {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
    init?(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, changed: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = address
        block = { _, _ in changed() }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block) == noErr else { return nil }
    }
    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }
}

struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let transportType: UInt32

    var outputSymbol: String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if ["headphone", "headset", "earbud", "beats"].contains(where: name.contains) { return "headphones" }
        switch transportType {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        default: return "hifispeaker"
        }
    }
    var sampleRate: Double {
        (try? HAL.read(id, HAL.address(kAudioDevicePropertyNominalSampleRate), default: Double(0))) ?? 0
    }

    static func all() throws -> [AudioDevice] {
        try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyDevices)).compactMap { id in
            guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("com.peterdpong.fader.") else { return nil }
            return AudioDevice(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName) ?? "Audio device",
                               inputChannels: HAL.channels(id, scope: kAudioDevicePropertyScopeInput),
                               outputChannels: HAL.channels(id, scope: kAudioDevicePropertyScopeOutput),
                               transportType: (try? HAL.read(id, HAL.address(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func volumeAddresses(input: Bool) -> [AudioObjectPropertyAddress] {
        let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        let main = HAL.address(kAudioDevicePropertyVolumeScalar, scope)
        if HAL.writable(id, main) { return [main] }
        let count = input ? inputChannels : outputChannels
        return (0..<count).map { HAL.address(kAudioDevicePropertyVolumeScalar, scope, $0 + 1) }.filter { HAL.writable(id, $0) }
    }
    func volume(input: Bool) -> Float? {
        let values = volumeAddresses(input: input).compactMap { try? HAL.read(id, $0, default: Float(0)) }
        return values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }
    func setVolume(_ value: Float, input: Bool) throws {
        for address in volumeAddresses(input: input) { try HAL.write(id, address, min(1, max(0, value))) }
    }
}

struct AudioSource: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]
    var isPlaying: Bool
    var isApplication: Bool

    @MainActor static func all() throws -> [AudioSource] {
        var grouped: [String: AudioSource] = [:]
        for object in try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyProcessObjectList)) {
            guard let pid = try? HAL.read(object, HAL.address(kAudioProcessPropertyPID), default: pid_t(0)),
                  pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let rawID = [HAL.string(object, kAudioProcessPropertyBundleID), app?.bundleIdentifier]
                .compactMap { $0 }.first { !$0.isEmpty } ?? "pid.\(pid)"
            // Nested browser audio helpers inherit the outer application's identity.
            var bundleURL = app?.bundleURL
            var pathBuffer = [CChar](repeating: 0, count: Int(FaderProcessPathMaxSize))
            let pathSize = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let executablePath = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let executableURL = app?.executableURL ?? (pathSize > 0 ? URL(fileURLWithPath: executablePath) : nil)
            if let executable = executableURL {
                let parts = executable.pathComponents
                if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
                    bundleURL = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...index])))
                }
            }
            let bundle = bundleURL.flatMap(Bundle.init(url:))
            let key = bundle?.bundleIdentifier ?? rawID
            guard key != Bundle.main.bundleIdentifier else { continue }
            let name = [bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                        bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                        app?.localizedName, executableURL?.lastPathComponent]
                .compactMap { $0 }.first { !$0.isEmpty } ?? rawID
            let playing = (try? HAL.read(object, HAL.address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) == 1
            if var existing = grouped[key] {
                existing.processes.append(object)
                existing.isPlaying = existing.isPlaying || playing
                grouped[key] = existing
            } else {
                grouped[key] = AudioSource(id: key, name: name,
                                          icon: bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? app?.icon,
                                          processes: [object], isPlaying: playing,
                                          isApplication: bundleURL?.pathExtension == "app")
            }
        }
        return grouped.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
