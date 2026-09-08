import SwiftUI

struct MixerPopover: View {
    @Bindable var model: MixerModel
    @Environment(\.openSettings) private var openSettings
    @State private var savingPreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Menu {
                    ForEach(model.presets) { preset in
                        Button { model.applyPreset(preset) } label: {
                            if model.currentPreset?.id == preset.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else { Text(preset.name) }
                        }
                    }
                    if !model.presets.isEmpty { Divider() }
                    Button("Save Current Mix…") { presetName = ""; savingPreset = true }
                    Button("Manage Presets…") { showSettings(.presets) }
                } label: {
                    Text(model.currentPreset?.name ?? "Presets").font(.headline).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Mix presets")
                Spacer()
                Menu {
                    Button("Settings…") { showSettings(.general) }.keyboardShortcut(",")
                    Button("Reset App Volumes and Outputs") { model.reset() }
                    Divider()
                    Button("Audio Access Settings…") { model.openAudioPrivacy() }
                    Button("Sound Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
                    }
                    Divider()
                    Button("Quit Fader") { model.shutdown(); NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Fader settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
            VStack(alignment: .leading, spacing: 14) {
                deviceSection(input: false)
                Divider()
                deviceSection(input: true)
            }.padding(14)

            Divider()
            Text("Applications")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if model.visibleSources.isEmpty {
                Text("No adjustable apps playing audio")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleSources) { source in
                            if source.id != model.visibleSources.first?.id {
                                Divider()
                            }
                            SourceRow(source: source, model: model)
                                .padding(.vertical, 8)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 6)
                }
                .frame(height: min(CGFloat(model.visibleSources.count) * 66, 330))
                .padding(.bottom, 8)
            }

            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss error")
                }.padding(14)
            }
        }
        .frame(width: 320)
        .alert("Save Current Mix", isPresented: $savingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { model.createPreset(name: presetName) }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func showSettings(_ tab: SettingsTab) {
        model.settingsTab = tab
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func deviceSection(input: Bool) -> some View {
        let devices = input ? model.inputs : model.outputs
        let selected = input ? model.inputID : model.outputID
        let volume = input ? model.inputVolume : model.outputVolume
        return VStack(alignment: .leading, spacing: 6) {
            Picker(input ? "Input" : "Output", selection: Binding(get: { selected }, set: { model.selectDevice($0, input: input) })) {
                if devices.isEmpty { Text("No Devices").tag(UInt32(0)) }
                ForEach(devices) { device in
                    Label(device.name, systemImage: input ? "mic" : device.outputSymbol).tag(device.id)
                }
            }
            .disabled(devices.isEmpty)
            .accessibilityLabel(input ? "Input device" : "Output device")

            if let volume {
                HStack(spacing: 8) {
                    Image(systemName: input ? "mic" : "speaker.wave.2")
                        .foregroundStyle(.secondary).frame(width: 20)
                    Slider(value: Binding(get: { Double(volume) }, set: { model.setDeviceVolume(Float($0), input: input) }), in: 0...1)
                        .accessibilityLabel(input ? "Microphone level" : "Output volume")
                    Text(volume.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
    }
}

private struct SourceRow: View {
    private static let volumeSnapPoints = [0, 50, 100, 150, 200, 300, 400]
    let source: AudioSource
    @Bindable var model: MixerModel

    var body: some View {
        let setting = model.preference(source.id)
        let selectedOutput = model.outputs.first { $0.uid == setting.outputUID }
        let effectiveOutput = selectedOutput ?? model.output
        let outputName = effectiveOutput?.name ?? "No Output Device"
        let outputHelp = setting.outputUID == nil ? "System Output: \(outputName)"
            : selectedOutput == nil ? "Saved output disconnected. Using \(outputName)" : "Output: \(outputName)"
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if let icon = source.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "app.dashed").resizable() }
                }.frame(width: 20, height: 20).accessibilityHidden(true)
                Text(source.name).lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    Picker("Output", selection: Binding(get: { setting.outputUID ?? "" }, set: { uid in
                        model.update(source.id) { $0.outputUID = uid.isEmpty ? nil : uid }
                    })) {
                        Label("System Output", systemImage: model.output?.outputSymbol ?? "speaker.wave.2").tag("")
                        ForEach(model.outputs) { device in
                            Label(device.name, systemImage: device.outputSymbol).tag(device.uid)
                        }
                        if let uid = setting.outputUID, !model.outputs.contains(where: { $0.uid == uid }) {
                            Text("Disconnected — Using System Output").tag(uid)
                        }
                    }.pickerStyle(.inline)
                } label: {
                    Image(systemName: effectiveOutput?.outputSymbol ?? "speaker.slash")
                        .foregroundStyle(.secondary).frame(width: 20, height: 20)
                }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(source.name) output: \(outputName)")
                    .help(outputHelp)

                Button {
                    model.update(source.id) { $0.volume = 1; $0.muted = false }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Reset volume to 100%")
                .accessibilityLabel("Reset \(source.name) volume to 100%")
            }
            HStack(spacing: 8) {
                Button {
                    model.update(source.id) { $0.muted.toggle() }
                } label: {
                    Image(systemName: setting.muted ? "speaker.slash" : "speaker.wave.2")
                        .foregroundStyle(setting.muted ? .primary : .secondary).frame(width: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(setting.muted ? "Unmute" : "Mute") \(source.name)")

                Slider(value: Binding(get: { Double(setting.volume) }, set: { volume in
                    let percent = Int((volume * 100).rounded())
                    let event = NSApp.currentEvent
                    let isMouseAdjustment = event?.type == .leftMouseDown || event?.type == .leftMouseDragged || event?.type == .leftMouseUp
                    // Magnetize mouse adjustments within five percentage points.
                    // Keyboard/accessibility and Option-drag retain fine control.
                    let shouldSnap = isMouseAdjustment && event?.modifierFlags.contains(.option) != true
                    let adjusted = shouldSnap ? Self.volumeSnapPoints.first { abs($0 - percent) <= 5 } ?? percent : percent
                    model.update(source.id) { $0.volume = Float(adjusted) / 100; $0.muted = false }
                }), in: 0...Double(SourceSettings.maximumVolume))
                    .opacity(setting.muted ? 0.4 : 1)
                    .accessibilityLabel("\(source.name) volume")
                    .accessibilityValue(setting.muted ? "Muted" : setting.volume.formatted(.percent.precision(.fractionLength(0))))
                    .help("Adjust \(source.name) from 0% to 400%. Snaps to common levels; hold Option for precise adjustment.")

                Text(setting.muted ? "Mute" : setting.volume.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.primary)
                    .frame(width: 34, alignment: .trailing)
                    .contextMenu {
                        ForEach(Self.volumeSnapPoints, id: \.self) { percent in
                            Button("Volume: \(percent)%") { model.update(source.id) { $0.volume = Float(percent) / 100; $0.muted = false } }
                        }
                    }
            }
            if let error = model.sourceErrors[source.id] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Audio Access…") { model.openAudioPrivacy() }
                    Button("Retry") { model.retry(source.id) }
                }.controlSize(.small)
            }
        }
    }
}
