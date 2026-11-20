import SwiftUI
import XAirKit

struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var manualIP = "192.168.1.1"
    @State private var scanning = false

    var body: some View {
        @Bindable var session = app.session
        NavigationStack {
            List {
                statusSection
                Section {
                    if app.session.discovered.isEmpty {
                        ContentUnavailableView {
                            Label(scanning ? "Searching…" : "No mixers found", systemImage: "dot.radiowaves.left.and.right")
                        } description: {
                            Text("Discovery sends a broadcast /xinfo probe on UDP 10024. If nothing appears, enter the mixer's IP address below. Broadcast discovery needs the local-network permission and, on a physical device, the multicast networking entitlement.")
                        }
                    }
                    ForEach(app.session.discovered) { d in
                        DeviceRow(device: d) { app.connect(d) }
                    }
                } header: {
                    Text("Mixers on this network")
                }

                Section("Connect by IP address") {
                    HStack {
                        TextField("IP address", text: $manualIP)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Mixer IP address")
                        Button("Connect") { app.connect(ip: manualIP) }
                            .buttonStyle(.glassProminent)
                            .disabled(!NetworkInterfaces.isValidIPv4(manualIP.trimmingCharacters(in: .whitespaces)))
                    }
                    Text("192.168.1.1 is the mixer's own access-point address. Manual connection uses a direct /xinfo and /status exchange and works without broadcast.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if !app.recentDevices.isEmpty {
                    Section("Recent") {
                        ForEach(app.recentDevices) { d in
                            DeviceRow(device: d) { app.connect(d) }
                        }
                    }
                }

                Section {
                    Picker("Synchronize", selection: $session.syncDirection) {
                        Text("Mixer → App (recommended)").tag(SyncDirection.mixerToApp)
                        Text("App → Mixer").tag(SyncDirection.appToMixer)
                    }
                    Toggle("Auto reconnect", isOn: $session.autoReconnect)
                } header: {
                    Text("Connection options")
                } footer: {
                    Text("App → Mixer pushes this app's current values to the mixer and then reads every node back.")
                }

                Section {
                    Menu {
                        ForEach(MixerModel.allCases, id: \.self) { m in
                            Button(m.displayName) { app.startOffline(model: m) }
                        }
                    } label: { Label("Edit offline…", systemImage: "icloud.slash") }
                } footer: {
                    Text("Offline editing starts from the default scene of the chosen model. Connect later with App → Mixer to send the changes, or export them as a scene file.")
                }

                Section {
                    ForEach(["XR18", "X18", "XR16", "XR12"], id: \.self) { m in
                        Button { app.startSimulator(model: m) } label: {
                            Label("Simulated \(m)", systemImage: "cpu")
                        }
                    }
                } header: {
                    Text("Without hardware")
                } footer: {
                    Text("Starts a deterministic X-Air protocol simulator on a private port on 127.0.0.1 and connects to it over UDP.")
                }
            }
            .navigationTitle("X Air Modern")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                }
            }
            .refreshable { rescan() }
            .task { if !ProcessInfo.processInfo.arguments.contains("-simulator") { rescan() } }
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch app.session.state {
        case .connecting(let ip):
            Section { Label("Connecting to \(ip)…", systemImage: "network").symbolEffect(.pulse) }
        case .failed(let msg):
            Section {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        default:
            EmptyView()
        }
        if let e = app.session.lastError, !isFailed {
            Section { Text(e).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private var isFailed: Bool { if case .failed = app.session.state { return true }; return false }

    private func rescan() {
        scanning = true
        app.session.discover()
        Task { try? await Task.sleep(for: .seconds(2)); scanning = false }
    }
}

struct DeviceRow: View {
    let device: MixerDevice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "slider.vertical.3")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name.isEmpty ? device.ip : device.name).font(.headline)
                    Text("\(device.modelString) · \(device.ip) · FW \(device.firmware)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !device.isFirmwareCompatible && !device.firmware.isEmpty {
                        Text("Firmware too old – update required").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects to this mixer")
    }
}
