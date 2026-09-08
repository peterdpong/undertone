import AppKit
import CoreAudio
import Observation
import ServiceManagement

@MainActor @Observable final class MixerModel {
    var devices: [AudioDevice] = []
    var sources: [AudioSource] = []
    var visibleSources: [AudioSource] = []
    var outputID: AudioObjectID = 0
    var outputVolume: Float?
    var errorMessage: String?
    var sourceErrors: [String: String] = [:]
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var settings: [String: SourceSettings] = [:]
    var presets = PresetLibrary().load()
    var settingsTab = SettingsTab.presets
    var selectedPresetID: UUID?
    private var sourceNames = UserDefaults.standard.dictionary(forKey: "sourceNames") as? [String: String] ?? [:]
    @ObservationIgnored private var mixers: [String: ProcessMixer] = [:]
    @ObservationIgnored private var bypassTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedConfigurations: [String: String] = [:]
    @ObservationIgnored private var systemObservers: [AudioObservation] = []
    @ObservationIgnored private var processObservers: [AudioObservation] = []
    @ObservationIgnored private var deviceObservers: [AudioObservation] = []
    @ObservationIgnored private var watchedProcesses: [AudioObjectID] = []
    @ObservationIgnored private var watchedDevices: [AudioObjectID] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var applicationSession = ApplicationSession()

    init() {
        if let data = UserDefaults.standard.data(forKey: "sourceSettings"),
           let saved = try? JSONDecoder().decode([String: SourceSettings].self, from: data) {
            settings = AudioMixingPolicy.sanitized(saved)
            if settings != saved { persistSettings() }
        }
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        systemObservers = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                           kAudioHardwarePropertyProcessObjectList]
            .compactMap { AudioObservation(HAL.system, HAL.address($0), changed: changed) }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.stopMixers() }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.sourceErrors = [:]; self?.refresh() }
        })
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
        refresh()
    }
    var outputs: [AudioDevice] { devices }
    var output: AudioDevice? { devices.first { $0.id == outputID } }
    func preference(_ id: String) -> SourceSettings {
        AudioMixingPolicy.isProtected(bundleID: id) ? SourceSettings() : settings[id] ?? SourceSettings()
    }

    var loudnessAppIDs: [String] {
        Set(sources.filter(\.isApplication).map(\.id))
            .union(visibleSources.map(\.id)).union(settings.keys)
            .filter { !AudioMixingPolicy.isProtected(bundleID: $0) }
            .sorted { sourceName($0).localizedStandardCompare(sourceName($1)) == .orderedAscending }
    }
    func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? sourceNames[id] ?? id
    }

    func snapshot() -> MixSnapshot {
        var values = settings.filter { $0.value != SourceSettings() }
        var names = sourceNames
        for source in visibleSources {
            if source.isApplication { values[source.id] = preference(source.id) }
            names[source.id] = source.name
        }
        return MixSnapshot(settings: values, names: names,
                           output: output.map { PresetDevice(uid: $0.uid, name: $0.name, volume: outputVolume) })
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
        settings = AudioMixingPolicy.sanitized(preset.mix.apps)
        sourceNames.merge(preset.mix.names) { _, new in new }
        persistSettings()
        sourceErrors = [:]
        failedConfigurations = [:]
        var issues: [String] = []
        if let saved = preset.mix.output {
            if let device = outputs.first(where: { $0.uid == saved.uid }) {
                do {
                    try HAL.write(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), device.id)
                    if let volume = saved.volume { try device.setVolume(volume) }
                } catch { issues.append(error.localizedDescription) }
            } else {
                issues.append("\(saved.name) is disconnected; kept the current output.")
            }
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
            devices = try AudioDevice.allOutputs()
            sources = try AudioSource.all()
            updateVisibleSources()
            outputID = HAL.defaultOutputDevice()
            outputVolume = output?.volume()
            loginEnabled = SMAppService.mainApp.status == .enabled
            updateObservers()
            reconcile()
        } catch { errorMessage = error.localizedDescription }
    }
    private func updateVisibleSources() {
        var running: [String: Set<pid_t>] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            if let id = app.bundleIdentifier { running[id, default: []].insert(app.processIdentifier) }
        }
        // CLI/background sources have no owning .app in NSWorkspace. Keep a
        // previously heard process while it lives, even if its audio object goes away.
        for source in sources + visibleSources where !source.isApplication {
            let alive = source.processIDs.filter { pid in
                kill(pid, 0) == 0 || errno == EPERM
            }
            running[source.id, default: []].formUnion(alive)
        }
        let visible = applicationSession.update(playing: Set(sources.filter(\.isPlaying).map(\.id)), running: running)
        let current = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let previous = Dictionary(uniqueKeysWithValues: visibleSources.map { ($0.id, $0) })
        visibleSources = visible.compactMap { id in
            if let source = current[id] { return source }
            guard var source = previous[id] else { return nil }
            // Cached display metadata must never carry stale Core Audio objects
            // into processing. Only the fresh `sources` list drives the engine.
            source.processes = []
            source.isPlaying = false
            return source
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        let deviceIDs = [outputID] + outputs.map(\.id)
        if deviceIDs != watchedDevices {
            watchedDevices = deviceIDs
            deviceObservers = outputs.flatMap { device -> [AudioObservation] in
                var addresses = device.id == outputID ? device.volumeAddresses() : []
                addresses += [HAL.address(kAudioDevicePropertyNominalSampleRate), HAL.address(kAudioDevicePropertyDeviceIsAlive)]
                return addresses.compactMap { AudioObservation(device.id, $0, changed: changed) }
            }
        }
    }
    func update(_ id: String, _ change: (inout SourceSettings) -> Void) {
        guard !AudioMixingPolicy.isProtected(bundleID: id) else { return }
        var value = preference(id)
        change(&value)
        value.volume = SourceSettings.clampedVolume(value.volume)
        settings[id] = value
        if let source = visibleSources.first(where: { $0.id == id }) { sourceNames[id] = source.name }
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
            if let mixer = mixers[id], mixer.outputUID == output?.uid,
               let source = sources.first(where: { $0.id == id && $0.isPlaying }),
               mixer.processes == source.processes.sorted() {
                // Finish a smooth return to unity before restoring direct audio.
                // This is a one-shot handoff, not a polling timer.
                mixer.update(preference(id))
                if bypassTasks[id] == nil {
                    bypassTasks[id] = Task { [weak self, weak mixer] in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled, let self, let mixer,
                              !self.preference(id).needsMixing, self.mixers[id] === mixer else { return }
                        self.mixers.removeValue(forKey: id)?.stop()
                        self.bypassTasks[id] = nil
                    }
                }
            } else {
                bypassTasks.removeValue(forKey: id)?.cancel()
                mixers.removeValue(forKey: id)?.stop()
            }
        }
        for source in sources where desired.contains(source.id) {
            bypassTasks.removeValue(forKey: source.id)?.cancel()
            let value = preference(source.id)
            // An unplugged chosen output falls back to the current system output.
            guard let target = outputs.first(where: { $0.uid == value.outputUID }) ?? output else {
                mixers.removeValue(forKey: source.id)?.stop()
                continue
            }
            if let mixer = mixers[source.id], mixer.processes == source.processes.sorted(),
               mixer.outputUID == target.uid, mixer.sampleRate == target.sampleRate {
                mixer.update(value)
                continue
            }
            mixers.removeValue(forKey: source.id)?.stop()
            let configuration = "\(source.processes.sorted())|\(target.uid)|\(target.sampleRate)"
            guard sourceErrors[source.id] == nil || failedConfigurations[source.id] != configuration else { continue }
            do {
                mixers[source.id] = try ProcessMixer(source: source, output: target, settings: value)
                sourceErrors[source.id] = nil
                failedConfigurations[source.id] = nil
            } catch {
                sourceErrors[source.id] = error.localizedDescription
                failedConfigurations[source.id] = configuration
            }
        }
    }
    private func stopMixers() {
        for task in bypassTasks.values { task.cancel() }
        bypassTasks = [:]
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
    func selectOutput(_ id: AudioObjectID) {
        do {
            try HAL.write(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), id)
            sourceErrors = [:]
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func setOutputVolume(_ value: Float) {
        do {
            try output?.setVolume(value)
            outputVolume = value
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
