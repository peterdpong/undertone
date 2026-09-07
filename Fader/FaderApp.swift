import SwiftUI

@main struct FaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: MixerModel

    init() {
        if CommandLine.arguments.contains("--diagnose") {
            do {
                for device in try AudioDevice.all() {
                    print("Device: \(device.name) | in=\(device.inputChannels) out=\(device.outputChannels) | output volume=\(device.volume(input: false).map(String.init(describing:)) ?? "hardware controlled")")
                }
                for source in try AudioSource.all() {
                    print("App: \(source.name) | \(source.id) | playing=\(source.isPlaying) | processes=\(source.processes)")
                }
                exit(0)
            } catch { print(error.localizedDescription); exit(1) }
        }
        let model = MixerModel()
        _model = State(initialValue: model)
        #if DEBUG
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 450),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Fader · Development Preview"
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: MixerPopover(model: model))
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        #endif
    }
    var body: some Scene {
        MenuBarExtra("Fader", systemImage: "slider.vertical.3") {
            MixerPopover(model: model)
                .onAppear { delegate.model = model; model.refresh() }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: MixerModel?
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
