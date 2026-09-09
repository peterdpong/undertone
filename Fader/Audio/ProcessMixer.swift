import CoreAudio
import Foundation

/// Owns a private tap and aggregate device. Original playback is muted only
/// while this IOProc is running, so stopping or quitting restores direct sound.
@MainActor final class ProcessMixer {
    let processes: [AudioObjectID]
    let outputUID: String
    let sampleRate: Double
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var renderState: OpaquePointer?

    init(source: AudioSource, output: AudioDevice, settings: SourceSettings) throws {
        guard !AudioMixingPolicy.isProtected(bundleID: source.id) else {
            throw AudioFailure(operation: "Call audio must stay on the macOS audio path", status: kAudioHardwareUnsupportedOperationError)
        }
        processes = source.processes.sorted()
        outputUID = output.uid
        sampleRate = output.sampleRate
        try start(name: source.name, output: output, settings: settings)
    }

    private func start(name: String, output: AudioDevice, settings: SourceSettings) throws {
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.name = "Fader · \(name)"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "Creating app audio tap")

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Fader · \(name)",
                kAudioAggregateDeviceUIDKey: "com.peterdpong.fader.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid,
                                                       kAudioSubDeviceInputChannelsKey: 0]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                 kAudioSubTapDriftCompensationKey: true]]
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Creating app audio output")

            // Physical input streams precede tap streams in an aggregate device.
            // Skip them explicitly; never route a microphone into the speakers.
            let tapFormat = try HAL.read(tap, HAL.address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
            guard tapFormat.mChannelsPerFrame == 2 else { throw unsupportedFormat() }
            let inputChannels = HAL.channels(aggregate, scope: kAudioDevicePropertyScopeInput)
            guard inputChannels >= 2 else { throw unsupportedFormat() }
            for scope in [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput] {
                let streams = try HAL.ids(aggregate, HAL.address(kAudioDevicePropertyStreams, scope))
                for stream in streams {
                    let format = try HAL.read(stream, HAL.address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
                    guard format.mFormatID == kAudioFormatLinearPCM,
                          format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                          format.mBitsPerChannel == 32,
                          format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { throw unsupportedFormat() }
                }
            }
            let renderRate = try HAL.read(aggregate, HAL.address(kAudioDevicePropertyNominalSampleRate), default: Double(0))
            guard let state = FaderRenderCreate(settings.gain, inputChannels - 2, renderRate) else { throw unsupportedFormat() }
            renderState = state
            FaderRenderSetLoudnessEqualization(state, settings.loudnessEqualization)
            try HAL.check(FaderCreateIOProc(aggregate, state, &ioProc), "Connecting app audio")
            try HAL.check(AudioDeviceStart(aggregate, ioProc), "Starting app audio; allow Fader in System Settings → Privacy & Security → Screen & System Audio Recording")
        } catch {
            stop()
            throw error
        }
    }
    func update(_ settings: SourceSettings) {
        if let renderState {
            FaderRenderSetGain(renderState, settings.gain)
            FaderRenderSetLoudnessEqualization(renderState, settings.loudnessEqualization)
        }
    }
    func stop() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
        }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let renderState { FaderRenderDestroy(renderState); self.renderState = nil }
    }
    isolated deinit { stop() }
    private func unsupportedFormat() -> AudioFailure {
        AudioFailure(operation: "This audio device does not provide a supported stereo Float32 stream", status: kAudioHardwareUnsupportedOperationError)
    }
}
