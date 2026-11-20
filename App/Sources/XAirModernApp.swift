import SwiftUI
import XAirKit

@main
struct XAirModernApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { LaunchOptions.apply(to: app) }
        }
        .commands { MixerCommands(app: app) }
    }
}

/// Launch arguments used for automated screenshots and simulator demos:
/// `-simulator XR18`, `-connect 192.168.1.10`, `-tab mixer`, `-strip 3`.
enum LaunchOptions {
    @MainActor static func apply(to app: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        func value(_ k: String) -> String? {
            guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let tab = value("-tab"), let t = AppTab(rawValue: tab) { app.selectedTab = t; if [.routing, .meters, .setup].contains(t) { app.toolsPage = t } }
        if let s = value("-strip"), let n = Int(s), (0..<36).contains(n) { app.selectedStrip = n }
        if let p = value("-setup-page") { app.requestedSetupPage = SetupPage(rawValue: p) }
        if let layer = value("-layer") {
            app.mixerLayer = MixerLayer.primary.first { $0.title.lowercased().hasPrefix(layer.lowercased()) } ?? .inputs
        }
        if let m = value("-simulator") { app.startSimulator(model: m) }
        else if let ip = value("-connect") { app.connect(ip: ip) }
    }
}

/// Native iPad keyboard menus. Command-modified keys leave typing in mixer name fields available.
struct MixerCommands: Commands {
    let app: AppModel
    var body: some Commands {
        CommandMenu("Mixer") {
            Group {
                ForEach(Array([AppTab.mixer, .channel, .effects, .scenes, .routing, .meters, .setup].enumerated()), id: \.offset) { index, tab in
                    Button(tab.rawValue.capitalized) { app.openTab(tab) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Button("RTA") { app.showingRTA = true; app.openTab(.meters) }
                if app.model.hasUSBRecorder {
                    Button("Recorder") { app.requestedSetupPage = .recorder; app.openTab(.setup) }
                }
                Menu("Fader layer") {
                    ForEach(MixerLayer.primary) { layer in
                        Button(layer.title) { app.mixerLayer = layer; app.openTab(.mixer) }
                    }
                    ForEach(0..<4) { d in
                        Button("DCA \(d + 1) spill") { app.mixerLayer = .dcaSpill(d); app.openTab(.mixer) }
                    }
                }
                Menu("Effect slot") {
                    ForEach(1...4, id: \.self) { slot in
                        Button("FX \(slot)") { app.selectedFXSlot = slot; app.openTab(.effects) }
                    }
                }
            }.disabled(!app.isOnline && !app.offlineEditing)
        }
        CommandMenu("Recorder") {
            recorder("Play", .play, "p")
            recorder("Pause / resume", .pause, "u")
            recorder("Stop", .stop, "s")
            recorder("Record / pause recording", .record, "r")
            recorder("Rewind", .rewind, .leftArrow)
            recorder("Fast forward", .fastForward, .rightArrow)
        }
        CommandMenu("Channel") {
            Group {
                Button("Previous channel") { app.selectedStrip = max(0, app.selectedStrip - 1) }.keyboardShortcut(.leftArrow)
                Button("Next channel") { app.selectedStrip = min(35, app.selectedStrip + 1) }.keyboardShortcut(.rightArrow)
                Button("First channel") { app.selectedStrip = 0 }.keyboardShortcut(.home)
                Button("Main LR") { app.selectedStrip = 31 }.keyboardShortcut(.end)
                Button("Raise fader") { app.stepFader(up: true) }.keyboardShortcut(.upArrow)
                Button("Lower fader") { app.stepFader(up: false) }.keyboardShortcut(.downArrow)
                Button("Mute or unmute") {
                    app.session.toggle(AppModel.base(of: app.selectedStrip) + (app.selectedStrip >= 32 ? "/on" : "/mix/on"))
                }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Toggle solo") { app.toggleSolo(strip: app.selectedStrip) }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(app.selectedStrip >= 32)
                Button("Edit name and colour") { app.channelSection = .config; app.openTab(.channel) }
                processing("Toggle gate", "gate", "g")
                processing("Toggle EQ", "eq", "e")
                processing("Toggle dynamics", "dyn", "d")
            }.disabled(!app.isOnline && !app.offlineEditing)
        }
    }

    private func recorder(_ title: String, _ action: RecorderAction, _ key: KeyEquivalent) -> some View {
        Button(title) { app.session.recorderTransport(action) }
            .keyboardShortcut(key, modifiers: [.command, .option])
            .disabled(!app.session.recorderAvailable || action.target(from: app.store.index("/-stat/tape/state")) == nil)
    }

    private func processing(_ title: String, _ node: String, _ key: KeyEquivalent) -> some View {
        let path = AppModel.base(of: app.selectedStrip) + "/" + node + "/on"
        return Button(title) { app.session.toggle(path) }
            .keyboardShortcut(key, modifiers: [.command, .shift]).disabled(app.store.spec(path) == nil)
    }
}
