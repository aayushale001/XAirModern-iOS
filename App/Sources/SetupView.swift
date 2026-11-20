import SwiftUI
import UniformTypeIdentifiers
import XAirKit

enum SetupPage: String, CaseIterable, Identifiable {
    case global = "Global", monitor = "Monitor / Solo", audioMidi = "Audio / MIDI", network = "Network",
         recorder = "Recorder", actions = "Mixer actions", info = "Info", firmware = "Firmware", app = "App preferences"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .global: "globe"
        case .monitor: "headphones"
        case .audioMidi: "pianokeys"
        case .network: "wifi"
        case .recorder: "record.circle"
        case .actions: "exclamationmark.arrow.triangle.2.circlepath"
        case .info: "info.circle"
        case .firmware: "arrow.down.circle"
        case .app: "iphone.gen3"
        }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var app
    var standalone = true

    var pages: [SetupPage] {
        SetupPage.allCases.filter { $0 != .recorder || app.model.hasUSBRecorder }
    }

    var body: some View {
        @Bindable var app = app
        ScreenContainer(standalone: standalone) {
            List(pages) { p in
                Button { app.requestedSetupPage = p } label: {
                    HStack { Label(p.rawValue, systemImage: p.icon); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }
            .navigationTitle("Setup")
            .navigationDestination(item: $app.requestedSetupPage) { page in
                Group {
                    switch page {
                    case .global: GlobalSetup()
                    case .monitor: MonitorSetup()
                    case .audioMidi: AudioMidiSetup()
                    case .network: NetworkSetup()
                    case .recorder: RecorderSetup()
                    case .actions: ActionsSetup()
                    case .info: InfoSetup()
                    case .firmware: FirmwareSetup()
                    case .app: AppPrefsSetup()
                    }
                }
                .navigationTitle(page.rawValue)
            }
            .toolbar { SessionToolbar() }
        }
    }
}

struct GlobalSetup: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Form {
            Section("Mixer") {
                ParamTextField(path: "/-prefs/name", label: "Mixer name")
                ParamToggle(path: "/-prefs/ponmute", label: "Mute outputs at power cycle")
                ParamToggle(path: "/-prefs/hardmute", label: "Hard mutes (mute groups mute hard)")
                ParamToggle(path: "/-prefs/dcamute", label: "DCA mutes")
                if app.model.hasUSBRecorder {
                    ParamToggle(path: "/-prefs/playnext", label: "Recorder play next")
                }
            }
            Section("Link preferences") {
                ParamToggle(path: "/config/linkcfg/preamp", label: "Link preamp (gain, phantom)")
                ParamToggle(path: "/config/linkcfg/eq", label: "Link EQ")
                ParamToggle(path: "/config/linkcfg/dyn", label: "Link dynamics")
                ParamToggle(path: "/config/linkcfg/fdrmute", label: "Link fader and mute")
            }
            Section("Channel links") {
                ForEach(stride(from: 1, to: 16, by: 2).map { $0 }, id: \.self) { a in
                    ParamToggle(path: "/config/chlink/\(a)-\(a + 1)", label: "Ch \(a)-\(a + 1)")
                }
                ForEach([1, 3, 5], id: \.self) { a in
                    ParamToggle(path: "/config/buslink/\(a)-\(a + 1)", label: "Bus \(a)-\(a + 1)")
                }
            }
            Section("Mute groups") {
                ForEach(1...4, id: \.self) { m in ParamToggle(path: "/config/mute/\(m)", label: "Mute group \(m)", tint: Theme.mute) }
            }
            Section("Automix") {
                ParamToggle(path: "/config/amixenable/X", label: "Automix group X")
                ParamToggle(path: "/config/amixenable/Y", label: "Automix group Y")
                ParamToggle(path: "/config/amixlock/X", label: "Lock X")
                ParamToggle(path: "/config/amixlock/Y", label: "Lock Y")
            }
        }
    }
}

struct MonitorSetup: View {
    var body: some View {
        Form {
            Section("Monitor") {
                ParamSlider(path: "/config/solo/level", label: "Monitor level", unit: "dB")
                ParamPicker(path: "/config/solo/source", label: "Monitor source")
                ParamSlider(path: "/config/solo/sourcetrim", label: "Source trim", unit: "dB")
            }
            Section("Solo") {
                ParamPicker(path: "/config/solo/chmode", label: "Channel solo", labels: ["PFL", "AFL"])
                ParamPicker(path: "/config/solo/busmode", label: "Bus solo", labels: ["PFL", "AFL"])
                ParamSlider(path: "/config/solo/dimatt", label: "Dim attenuation", unit: "dB")
                ParamToggle(path: "/config/solo/dim", label: "Dim")
                ParamToggle(path: "/config/solo/dimpfl", label: "PFL dim")
                ParamToggle(path: "/config/solo/mono", label: "Mono")
                ParamToggle(path: "/config/solo/mute", label: "Mute monitor", tint: Theme.mute)
                ParamToggle(path: "/-stat/solo", label: "Solo active (read-only indicator)").disabled(true)
            }
        }
    }
}

struct AudioMidiSetup: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        Form {
            if app.model.hasUSBAudioInterface {
                Section {
                    ParamPicker(path: "/-prefs/clockrate", label: "Sample rate", labels: ["48 kHz", "44.1 kHz"])
                    ParamPicker(path: "/-prefs/usbifcmode", label: "USB interface", labels: ["18/18 channels", "2/2 channels"])
                } header: { Text("Audio") }
            }
            Section {
                BitmaskList(path: "/-prefs/midiconfig", labels: ["DIN Rx", "DIN Tx", "DIN X-OSC", "USB Rx", "USB Tx", "USB/OSC", "USB-DIN pass-through"])
            } header: { Text("MIDI") }
        }
    }
}

struct BitmaskList: View {
    @Environment(AppModel.self) private var app
    let path: String
    let labels: [String]
    var body: some View {
        let v = app.store.index(path)
        ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
            Toggle(l, isOn: Binding(get: { v & (1 << i) != 0 }, set: { on in
                app.session.set(path, index: on ? v | (1 << i) : v & ~(1 << i))
            }))
        }
    }
}

struct NetworkSetup: View {
    @Environment(AppModel.self) private var app
    @State private var confirmApply: Int?
    var body: some View {
        Form {
            Section("Current") {
                LabeledContent("Network mode", value: app.store.display("/-stat/netmode"))
                LabeledContent("This device", value: NetworkInterfaces.localAddresses().joined(separator: ", "))
            }
            Section("LAN") {
                ParamPicker(path: "/-prefs/lan/mode", label: "Mode", labels: ["Static", "DHCP", "DHCP server"])
                OctetRow(base: "/-prefs/lan/addr", label: "IP")
                OctetRow(base: "/-prefs/lan/mask", label: "Subnet")
                OctetRow(base: "/-prefs/lan/gateway", label: "Gateway")
                Button("Apply LAN settings") { confirmApply = 1 }
            }
            Section("Access point") {
                ParamTextField(path: "/-prefs/ap/ssid", label: "SSID")
                ParamPicker(path: "/-prefs/ap/security", label: "Security")
                SecureParamField(path: "/-prefs/ap/key", label: "Key")
                ParamStepper(path: "/-prefs/ap/channel", label: "Channel")
                Button("Apply access point settings") { confirmApply = 3 }
            }
            Section("Wi-Fi client (infrastructure)") {
                ParamTextField(path: "/-prefs/is/ssid", label: "SSID")
                ParamPicker(path: "/-prefs/is/security", label: "Security")
                SecureParamField(path: "/-prefs/is/key", label: "Key")
                ParamPicker(path: "/-prefs/is/mode", label: "Addressing", labels: ["Static", "DHCP"])
                OctetRow(base: "/-prefs/is/addr", label: "IP")
                OctetRow(base: "/-prefs/is/mask", label: "Subnet")
                OctetRow(base: "/-prefs/is/gateway", label: "Gateway")
                Button("Scan for networks") {
                    app.session.set("/-action/wlanscan", index: 1)
                    Task { try? await Task.sleep(for: .seconds(2)); for i in 1...10 { app.session.requestNode(String(format: "/-stat/networks/%02d", i)) } }
                }
                ForEach(1...10, id: \.self) { i in
                    let p = String(format: "/-stat/networks/%02d", i)
                    let ssid = app.store.string(p + "/ssid")
                    if !ssid.isEmpty {
                        Button { app.session.set("/-prefs/is/ssid", string: ssid) } label: {
                            LabeledContent(ssid, value: "\(app.store.index(p + "/strength"))%")
                        }
                    }
                }
                Button("Apply Wi-Fi client settings") { confirmApply = 2 }
            }
        }
        .confirmationDialog("Apply network settings?", isPresented: Binding(get: { confirmApply != nil }, set: { if !$0 { confirmApply = nil } })) {
            Button("Apply", role: .destructive) { if let m = confirmApply { app.session.set("/-action/updnet", index: m) } }
        } message: { Text("The mixer will change its network configuration. This connection may drop.") }
    }
}

struct OctetRow: View {
    @Environment(AppModel.self) private var app
    let base: String
    let label: String
    var body: some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            ForEach(0..<4, id: \.self) { i in
                let p = base + "/\(i)"
                TextField("0", value: Binding(get: { app.store.index(p) }, set: { app.session.set(p, index: $0) }), format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(label) octet \(i + 1)")
                if i < 3 { Text(".") }
            }
        }
    }
}

struct SecureParamField: View {
    @Environment(AppModel.self) private var app
    let path: String
    let label: String
    @State private var reveal = false
    @State private var text = ""
    var body: some View {
        HStack {
            Group {
                if reveal { TextField(label, text: $text) } else { SecureField(label, text: $text) }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .onAppear { text = app.store.string(path) }
            .onSubmit { app.session.set(path, string: text) }
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                .accessibilityLabel(reveal ? "Hide password" : "Show password")
            Button("Set") { app.session.set(path, string: text) }.buttonStyle(.bordered)
        }
    }
}

struct RecorderSetup: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let session = app.session
        let state = app.store.index("/-stat/tape/state")
        let path = app.store.string("/-stat/usb/path")
        Form {
            Section("Transport") {
                LabeledContent("State", value: app.store.display("/-stat/tape/state"))
                    .accessibilityIdentifier("transport-state").accessibilityValue(app.store.display("/-stat/tape/state"))
                LabeledContent("File", value: app.store.string("/-stat/tape/file").isEmpty ? "—" : app.store.string("/-stat/tape/file"))
                    .accessibilityIdentifier("transport-file").accessibilityValue(app.store.string("/-stat/tape/file"))
                LabeledContent("Elapsed", value: Self.time(app.store.index("/-stat/tape/etime")))
                LabeledContent("Remaining", value: Self.time(app.store.index("/-stat/tape/rtime")))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))]) {
                    transport("stop.fill", .stop, "Stop", state)
                    transport("play.fill", .play, "Play", state)
                    transport("pause.fill", .pause, "Pause", state)
                    transport("record.circle", .record, "Record", state)
                    transport("backward.fill", .rewind, "Rewind", state)
                    transport("forward.fill", .fastForward, "Fast forward", state)
                }
                HStack {
                    trackButton(forward: false)
                    Spacer()
                    trackButton(forward: true)
                }
                ParamToggle(path: "/-prefs/playnext", label: "Play next automatically")
            }.disabled(!session.recorderAvailable)
            Section("Recorder meters") {
                let m = session.meters
                MeterRow(labels: ["Record L", "Record R", "Play L", "Play R"],
                         values: (0..<4).map { m.dB(.recorder, $0) }, height: 65)
            }
            Section("Recording inputs") {
                ForEach(1...2, id: \.self) { side in
                    let route = String(format: "/routing/usb/%02d", side)
                    ParamPicker(path: route + "/src", label: side == 1 ? "Left source" : "Right source",
                                labels: app.store.schema.labels["recorderSource"])
                    ParamPicker(path: route + "/pos", label: side == 1 ? "Left tap" : "Right tap",
                                labels: app.store.schema.labels["routingTaps"])
                }
            }
            Section("USB stick") {
                if !app.store.bool("/-stat/usbmounted") { Label("No USB stick detected", systemImage: "externaldrive.badge.xmark") }
                else {
                    LabeledContent("Folder", value: path.isEmpty ? "/" : path)
                    if !path.isEmpty && path != "/" {
                        Button("Parent folder", systemImage: "arrow.up.backward") { session.recorderParentDirectory() }
                            .disabled(session.directoryLoading)
                    }
                    if session.directoryLoading { ProgressView("Reading directory") }
                    else if let error = session.directoryError { Text(error).foregroundStyle(.secondary) }
                    else if session.recorderEntries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
                    ForEach(session.recorderEntries) { entry in
                        Button { session.openRecorderEntry(entry) } label: {
                            Label(entry.name, systemImage: entry.isFolder ? "folder" : "play.circle")
                        }
                        .accessibilityHint(entry.isFolder ? "Opens folder" : "Plays track")
                    }
                    Button("Refresh directory", systemImage: "arrow.clockwise") { session.refreshRecorderDirectory() }
                        .disabled(session.directoryLoading)
                }
            }
        }
        .meterSubscriptions([9])
    }

    private func transport(_ icon: String, _ action: RecorderAction, _ label: String, _ state: Int) -> some View {
        Button { app.session.recorderTransport(action) } label: { Image(systemName: icon).frame(minWidth: 32, minHeight: 32) }
            .buttonStyle(.glass).tint(action == .record ? .red : .accentColor)
            .accessibilityLabel(label).disabled(action.target(from: state) == nil)
    }

    private func trackButton(forward: Bool) -> some View {
        let track = app.session.adjacentTrack(forward: forward)
        return Button(forward ? "Next track" : "Previous track", systemImage: forward ? "forward.end.fill" : "backward.end.fill") {
            if let track { app.session.openRecorderEntry(track, play: false) }
        }.buttonStyle(.borderless).disabled(track == nil)
    }

    static func time(_ s: Int) -> String { s < 0 ? "**:**:**" : String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
}

struct ActionsSetup: View {
    @Environment(AppModel.self) private var app
    @State private var confirmInit = false
    var body: some View {
        Form {
            Section {
                Button("Save mixer state now") { app.session.set("/-action/savestate", index: 1) }
                Button("Clear all solos") { app.session.set("/-action/clearsolo", index: 1) }
                Button("Set mixer clock to this device's time") {
                    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss"
                    app.session.set("/-action/setclock", string: f.string(from: Date()))
                }
            }
            Section {
                Button("Initialize all mixer settings…", role: .destructive) { confirmInit = true }
            } footer: { Text("Resets the mixer to factory settings (/-action/initall).") }
        }
        .confirmationDialog("Initialize ALL settings?", isPresented: $confirmInit) {
            Button("Initialize", role: .destructive) {
                app.session.set("/-action/initall", index: 1)
                Task { try? await Task.sleep(for: .seconds(1)); app.session.resync() }
            }
        }
    }
}

struct InfoSetup: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let d = app.session.device
        Form {
            Section("Mixer") {
                LabeledContent("Name", value: d?.name ?? "—")
                LabeledContent("Model", value: d?.modelString ?? "—")
                LabeledContent("IP address", value: d?.ip ?? "—")
                LabeledContent("Firmware", value: d?.firmware ?? "—")
                if let d {
                    let hw = MixerHardware(modelString: d.modelString)
                    LabeledContent("Hardware", value: hw.isV2 ? "V2" : (hw.hasAlternateWiFi ? "W (alternate Wi-Fi)" : "V1"))
                }
            }
            Section("Capabilities") {
                let m = app.model
                LabeledContent("Channels", value: "\(m.channelCount)")
                LabeledContent("Mic preamps", value: "\(m.micPreampCount)")
                LabeledContent("Aux outputs", value: "\(m.auxOutputCount)")
                LabeledContent("USB audio interface", value: m.hasUSBAudioInterface ? "18×18" : "No")
                LabeledContent("USB stick recorder", value: m.hasUSBRecorder ? "Yes" : "No")
            }
            Section("Link statistics") {
                LabeledContent("Packets in / out", value: "\(app.session.stats.packetsIn) / \(app.session.stats.packetsOut)")
                LabeledContent("Decode errors", value: "\(app.session.stats.decodeErrors)")
                LabeledContent("Sync failures", value: "\(app.session.syncFailures.count)")
            }
        }
    }
}

struct FirmwareSetup: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var file: (name: String, data: Data)?
    @State private var problem: String?
    @State private var acknowledged = false
    @State private var phase: FirmwareUpdater.Phase = .idle
    @State private var confirm = false

    var body: some View {
        Form {
            Section {
                Label("Updating firmware can make the mixer unusable if it is interrupted or the wrong file is used. Keep the mixer powered and the network stable.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Section("Update file") {
                Button("Choose .update file…") { importing = true }
                if let file { LabeledContent("File", value: "\(file.name) (\(file.data.count / 1024) KB)") }
                if let problem { Text(problem).foregroundStyle(.red) }
            }
            Section {
                Toggle("I own this mixer and authorize a firmware update", isOn: $acknowledged)
                Button("Update firmware", role: .destructive) { confirm = true }
                    .disabled(file == nil || problem != nil || !acknowledged || app.session.device == nil)
                switch phase {
                case .idle: EmptyView()
                case .handshake: Text("Contacting updater on UDP 10018…")
                case .transferring(let p): ProgressView("Transferring data…", value: p)
                case .programming: ProgressView("Programming…")
                case .rebooting: Label("Device will reboot now!", systemImage: "checkmark.circle")
                case .failed(let m): Text(m).foregroundStyle(.red)
                }
            } footer: {
                Text("Uses the original update protocol (us** / sW** / sUpd / ur** on UDP 10018). Tested only against a simulated updater.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { r in
            guard let url = app.fileURL(r) else { return }
            guard let data = readSecurityScopedData(url) else {
                file = nil
                problem = "Could not read the selected firmware file."
                return
            }
            file = (url.lastPathComponent, data)
            let isV2 = MixerHardware(modelString: app.session.device?.modelString ?? "").isV2
            switch FirmwareFileCheck.validate(fileName: url.lastPathComponent, size: data.count, hardwareIsV2: isV2) {
            case .success: problem = nil
            case .failure(.notAnUpdateFile): problem = "This wasn't a valid file… (expected a .update file)"
            case .failure(.wrongHardwareGeneration(let v2)): problem = "Wrong update file! Please use a \(v2 ? "V2" : "V1") update file."
            case .failure: problem = "Failed to open update file…"
            }
        }
        .confirmationDialog("Start firmware update?", isPresented: $confirm) {
            Button("Update", role: .destructive) { start() }
        }
    }

    private func start() {
        guard let file, let ip = app.session.device?.ip else { return }
        let updater = FirmwareUpdater(transport: UDPSocketTransport(), host: ip)
        let data = file.data
        Task {
            do {
                try await updater.run(firmware: data, authorized: acknowledged) { p in Task { @MainActor in phase = p } }
            } catch {
                phase = .failed("Update failed, please try again! (\(error))")
            }
        }
    }
}

struct AppPrefsSetup: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        @Bindable var app = app
        @Bindable var session = app.session
        Form {
            Section("Connection") {
                Toggle("Auto connect to last mixer at launch", isOn: $app.autoConnect)
                Picker("Sync direction", selection: $session.syncDirection) {
                    Text("Mixer → App").tag(SyncDirection.mixerToApp)
                    Text("App → Mixer").tag(SyncDirection.appToMixer)
                }
                Toggle("Auto reconnect", isOn: $session.autoReconnect)
            }
            Section {
                Toggle("Meters at 50% rate", isOn: $session.meterHalfRate)
                Toggle("RTA at 50% rate", isOn: $session.rtaHalfRate)
            } header: { Text("Meters") } footer: { Text("Halves the /batchsubscribe time factor, like the original Meter 50% / RTA 50% preferences.") }
            Section("Interface") {
                Toggle("Confirm pop-ups", isOn: $app.confirmPopups)
                Toggle("Show On instead of Mute", isOn: $app.invertMutes)
                Toggle("Fine fader movement", isOn: $app.fineFaders)
                Toggle("Select strip on fader move", isOn: $app.selectOnFader)
                Toggle("Link send tap points across channels", isOn: $session.linkSendTaps)
                    .onChange(of: session.linkSendTaps) { app.savePreferences() }
                Toggle("Exclusive solo", isOn: $app.exclusiveSolo)
                Toggle("Follow last solo (select soloed channel)", isOn: $app.followSolo)
            }
            Section("User layers") {
                UserLayerEditor(title: "User 1", strips: $app.userLayer1)
                UserLayerEditor(title: "User 2", strips: $app.userLayer2)
            }
        }
        .onDisappear { app.savePreferences() }
    }
}

struct UserLayerEditor: View {
    @Environment(AppModel.self) private var app
    let title: String
    @Binding var strips: [Int]
    var body: some View {
        DisclosureGroup(title) {
            ForEach(0..<36, id: \.self) { s in
                Toggle(app.stripName(s), isOn: Binding(get: { strips.contains(s) }, set: { on in
                    if on { strips.append(s); strips.sort() } else { strips.removeAll { $0 == s } }
                }))
            }
        }
    }
}
