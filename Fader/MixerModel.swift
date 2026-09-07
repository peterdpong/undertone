import AppKit
import CoreAudio
import Observation
import ServiceManagement

@MainActor @Observable final class MixerModel {
    var devices: [AudioDevice] = []
    var sources: [AudioSource] = []
    var outputID: AudioObjectID = 0
    var inputID: AudioObjectID = 0
    var outputVolume: Float?
    var inputVolume: Float?
    var errorMessage: String?
    var sourceErrors: [String: String] = [:]
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var settings: [String: SourceSettings] = [:]
    var presets = PresetLibrary().load()
    var settingsTab = SettingsTab.presets
    var selectedPresetID: UUID?
    private var sourceNames = UserDefaults.standard.dictionary(forKey: "sourceNames") as? [String: String] ?? [:]
    @ObservationIgnored private var mixers: [String: ProcessMixer] = [:]
    @ObservationIgnored private var failedConfigurations: [String: String] = [:]
    @ObservationIgnored private var systemObservers: [AudioObservation] = []
    @ObservationIgnored private var processObservers: [AudioObservation] = []
    @ObservationIgnored private var deviceObservers: [AudioObservation] = []
    @ObservationIgnored private var watchedProcesses: [AudioObjectID] = []
    @ObservationIgnored private var watchedDevices: [AudioObjectID] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var sleeping = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "sourceSettings"),
           let saved = try? JSONDecoder().decode([String: SourceSettings].self, from: data) {
            settings = saved.mapValues { value in
                var value = value
                value.volume = SourceSettings.clampedVolume(value.volume)
                return value
            }
        }
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        systemObservers = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyProcessObjectList]
            .compactMap { AudioObservation(HAL.system, HAL.address($0), changed: changed) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.stopMixers() }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.sourceErrors = [:]; self?.refresh() }
        })
        refresh()
    }
    var outputs: [AudioDevice] { devices.filter { $0.outputChannels > 0 } }
    var inputs: [AudioDevice] { devices.filter { $0.inputChannels > 0 } }
    var output: AudioDevice? { devices.first { $0.id == outputID } }
    var input: AudioDevice? { devices.first { $0.id == inputID } }
    var visibleSources: [AudioSource] {
        // Filter on Core Audio output activity, not the saved volume: muted
        // sources stay reachable while playing, and paused apps keep preferences.
        sources.filter(\.isPlaying)
    }
    func preference(_ id: String) -> SourceSettings { settings[id] ?? SourceSettings() }

    func snapshot() -> MixSnapshot {
        var values = settings.filter { $0.value != SourceSettings() }
        var names = sourceNames
        for source in sources {
            if source.isApplication && source.isPlaying { values[source.id] = preference(source.id) }
            names[source.id] = source.name
        }
        return MixSnapshot(settings: values, names: names,
                           output: output.map { PresetDevice(uid: $0.uid, name: $0.name, volume: outputVolume) },
                           input: input.map { PresetDevice(uid: $0.uid, name: $0.name, volume: inputVolume) })
    }

    var currentPreset: MixPreset? {
        let current = snapshot()
        return presets.first { $0.mix.matches(current) }
    }

    @discardableResult func createPreset(name: String) -> MixPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = MixPreset(name: trimmed.isEmpty ? "New Preset" : trimmed, mix: snapshot())
        presets.append(preset)
        PresetLibrary().save(presets)
        selectedPresetID = preset.id
        return preset
    }

    func savePreset(_ preset: MixPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty else { return }
        presets[index] = preset
        PresetLibrary().save(presets)
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if selectedPresetID == id { selectedPresetID = presets.first?.id }
        PresetLibrary().save(presets)
    }

    func applyPreset(_ preset: MixPreset) {
        // Replace the mix so boosts from a previous preset cannot leak into this one.
        settings = preset.mix.apps.mapValues {
            var value = $0
            value.volume = SourceSettings.clampedVolume(value.volume)
            return value
        }
        sourceNames.merge(preset.mix.names) { _, new in new }
        persistSettings()
        sourceErrors = [:]
        failedConfigurations = [:]
        var issues: [String] = []
        for isInput in [false, true] {
            guard let saved = isInput ? preset.mix.input : preset.mix.output else { continue }
            guard let device = (isInput ? inputs : outputs).first(where: { $0.uid == saved.uid }) else {
                issues.append("\(saved.name) is disconnected; kept the current \(isInput ? "input" : "output").")
                continue
            }
            do {
                try HAL.write(HAL.system, HAL.address(isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), device.id)
                if let volume = saved.volume { try device.setVolume(volume, input: isInput) }
            } catch { issues.append(error.localizedDescription) }
        }
        errorMessage = issues.isEmpty ? nil : issues.joined(separator: "\n")
        refresh()
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "sourceSettings") }
        UserDefaults.standard.set(sourceNames, forKey: "sourceNames")
    }

    func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshTask = nil
            self?.refresh()
        }
    }
    func refresh() {
        do {
            devices = try AudioDevice.all()
            sources = try AudioSource.all()
            outputID = HAL.defaultDevice(input: false)
            inputID = HAL.defaultDevice(input: true)
            outputVolume = output?.volume(input: false)
            inputVolume = input?.volume(input: true)
            loginEnabled = SMAppService.mainApp.status == .enabled
            updateObservers()
            reconcile()
        } catch { errorMessage = error.localizedDescription }
    }
    private func updateObservers() {
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        let processIDs = sources.flatMap(\.processes).sorted()
        if processIDs != watchedProcesses {
            watchedProcesses = processIDs
            processObservers = processIDs.compactMap {
                AudioObservation($0, HAL.address(kAudioProcessPropertyIsRunningOutput), changed: changed)
            }
        }
        let deviceIDs = [outputID, inputID] + outputs.map(\.id)
        if deviceIDs != watchedDevices {
            watchedDevices = deviceIDs
            deviceObservers = [output, input].enumerated().flatMap { index, device -> [AudioObservation] in
                guard let device else { return [] }
                var addresses = device.volumeAddresses(input: index == 1)
                addresses += [HAL.address(kAudioDevicePropertyNominalSampleRate), HAL.address(kAudioDevicePropertyDeviceIsAlive)]
                return addresses.compactMap { AudioObservation(device.id, $0, changed: changed) }
            }
            deviceObservers += outputs.flatMap { device in
                [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive].compactMap {
                    AudioObservation(device.id, HAL.address($0), changed: changed)
                }
            }
        }
    }
    func update(_ id: String, _ change: (inout SourceSettings) -> Void) {
        var value = preference(id)
        change(&value)
        value.volume = SourceSettings.clampedVolume(value.volume)
        settings[id] = value
        if let source = sources.first(where: { $0.id == id }) { sourceNames[id] = source.name }
        sourceErrors[id] = nil
        persistSettings()
        reconcile()
    }
    func reset() {
        stopMixers()
        settings = [:]
        sourceErrors = [:]
        UserDefaults.standard.removeObject(forKey: "sourceSettings")
    }
    func retry(_ id: String) { sourceErrors[id] = nil; reconcile() }

    private func reconcile() {
        guard !sleeping else { stopMixers(); return }
        let desired = Set(sources.filter { preference($0.id).needsMixing && $0.isPlaying }.map(\.id))
        for id in Array(mixers.keys) where !desired.contains(id) {
            mixers.removeValue(forKey: id)?.stop()
        }
        for source in sources where desired.contains(source.id) {
            let value = preference(source.id)
            // An unplugged chosen output falls back to the current system output.
            guard let target = outputs.first(where: { $0.uid == value.outputUID }) ?? output else {
                mixers.removeValue(forKey: source.id)?.stop()
                continue
            }
            if let mixer = mixers[source.id], mixer.processes == source.processes.sorted(),
               mixer.outputUID == target.uid, mixer.sampleRate == target.sampleRate {
                mixer.setGain(value.gain)
                continue
            }
            mixers.removeValue(forKey: source.id)?.stop()
            let configuration = "\(source.processes.sorted())|\(target.uid)|\(target.sampleRate)"
            guard sourceErrors[source.id] == nil || failedConfigurations[source.id] != configuration else { continue }
            do {
                mixers[source.id] = try ProcessMixer(source: source, output: target, gain: value.gain)
                sourceErrors[source.id] = nil
                failedConfigurations[source.id] = nil
            } catch {
                sourceErrors[source.id] = error.localizedDescription
                failedConfigurations[source.id] = configuration
            }
        }
    }
    private func stopMixers() {
        for mixer in mixers.values { mixer.stop() }
        mixers = [:]
    }
    func shutdown() {
        refreshTask?.cancel()
        systemObservers = []; processObservers = []; deviceObservers = []
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens = []
        stopMixers()
    }
    func selectDevice(_ id: AudioObjectID, input: Bool) {
        do {
            try HAL.write(HAL.system, HAL.address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), id)
            sourceErrors = [:]
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func setDeviceVolume(_ value: Float, input: Bool) {
        do {
            try (input ? self.input : output)?.setVolume(value, input: input)
            if input { inputVolume = value } else { outputVolume = value }
        } catch { errorMessage = error.localizedDescription }
    }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { errorMessage = error.localizedDescription }
    }
    func openAudioPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}
