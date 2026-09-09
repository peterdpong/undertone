import SwiftUI

enum SettingsTab: Hashable { case general, presets }

struct SettingsView: View {
    @Bindable var model: MixerModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Form {
                Toggle("Launch Fader at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                LabeledContent("Audio access") {
                    Button("Open System Settings…") { model.openAudioPrivacy() }
                }
                Section {
                    if model.loudnessAppIDs.isEmpty {
                        Text("Play audio in an app to add it here.").foregroundStyle(.secondary)
                    }
                    ForEach(model.loudnessAppIDs, id: \.self) { id in
                        Toggle(model.sourceName(id), isOn: Binding(
                            get: { model.preference(id).loudnessEqualization },
                            set: { enabled in model.update(id) { $0.loudnessEqualization = enabled } }
                        ))
                        .accessibilityLabel("\(model.sourceName(id)) loudness equalization")
                    }
                } header: {
                    Text("Loudness Equalization")
                } footer: {
                    Text("Even out quiet and loud passages with automatic volume adjustment. Saved with your presets.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)

            PresetsSettingsView(model: model)
                .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }.tag(SettingsTab.presets)
        }
        .frame(width: 620, height: 440)
    }
}

private struct PresetsSettingsView: View {
    @Bindable var model: MixerModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selectedPresetID) {
                    ForEach(model.presets) { preset in
                        Label(preset.name, systemImage: "slider.horizontal.3").tag(preset.id)
                    }
                }
                Divider()
                HStack(spacing: 12) {
                    Button { model.createPreset(name: "New Preset") } label: { Image(systemName: "plus") }
                        .help("Create preset from current mix").accessibilityLabel("Create preset from current mix")
                    Button {
                        if let id = model.selectedPresetID { model.deletePreset(id) }
                    } label: { Image(systemName: "minus") }
                        .disabled(model.selectedPresetID == nil)
                        .help("Delete preset").accessibilityLabel("Delete preset")
                    Spacer()
                }.buttonStyle(.borderless).padding(10)
            }.frame(width: 190)
            Divider()
            if let preset = model.presets.first(where: { $0.id == model.selectedPresetID }) {
                PresetDetail(preset: preset, model: model).id(preset.id)
            } else {
                ContentUnavailableView {
                    Label("No Preset Selected", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Save your current mix to use it again later.")
                } actions: {
                    Button("Save Current Mix…") { model.createPreset(name: "New Preset") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if model.selectedPresetID == nil { model.selectedPresetID = model.presets.first?.id }
        }
    }
}

private struct PresetDetail: View {
    let preset: MixPreset
    @Bindable var model: MixerModel
    @State private var draft: MixPreset

    init(preset: MixPreset, model: MixerModel) {
        self.preset = preset
        self.model = model
        _draft = State(initialValue: preset)
    }

    private var changed: Bool { draft != preset }
    private var valid: Bool { !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Preset name", text: $draft.name).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Preset name")
                    outputRow(draft.mix.output)
                    Divider()
                    if draft.mix.apps.isEmpty {
                        Text("No saved app levels").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(draft.mix.apps.keys.sorted {
                                (draft.mix.names[$0] ?? $0).localizedStandardCompare(draft.mix.names[$1] ?? $1) == .orderedAscending
                            }, id: \.self) { id in
                                if let value = draft.mix.apps[id] {
                                    HStack(spacing: 8) {
                                        appIcon(id).frame(width: 20, height: 20).accessibilityHidden(true)
                                        Text(draft.mix.names[id] ?? id).lineLimit(1)
                                        Spacer(minLength: 4)
                                        if value.loudnessEqualization {
                                            Image(systemName: "waveform.path")
                                                .help("Loudness Equalization enabled")
                                                .accessibilityLabel("Loudness Equalization enabled")
                                        }
                                        if value.outputUID != nil {
                                            Image(systemName: "arrow.triangle.branch")
                                                .help(model.outputs.first { $0.uid == value.outputUID }?.name ?? "Saved output (disconnected)")
                                        }
                                        Text(value.muted ? "Muted" : value.volume.formatted(.percent.precision(.fractionLength(0))))
                                            .monospacedDigit()
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                    }
                    Button("Use Current Mix") { draft.mix = model.snapshot() }
                        .help("Replace this preset’s saved levels and devices with the current mix")
                }.padding(20)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Button("Revert") { draft = preset }.disabled(!changed)
                Spacer()
                Button("Save") { model.savePreset(draft) }.disabled(!changed || !valid)
                    .keyboardShortcut("s", modifiers: .command)
                Button("Apply") { model.applyPreset(preset) }.disabled(changed || !valid)
                    .help(changed ? "Save changes before applying" : "Apply this preset")
            }.padding(12)
        }
        .onChange(of: preset) { _, updated in draft = updated }
    }

    private func outputRow(_ device: PresetDevice?) -> some View {
        HStack {
            Image(systemName: "speaker.wave.2").frame(width: 20)
            Text(device?.name ?? "No output").lineLimit(1)
            Spacer()
            if let volume = device?.volume {
                Text(volume.formatted(.percent.precision(.fractionLength(0)))).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func appIcon(_ id: String) -> some View {
        if AudioSource.isSystemSound(id) {
            Image(systemName: "bell.fill").resizable().scaledToFit()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app.dashed").resizable()
        }
    }
}
