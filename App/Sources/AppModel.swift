import Foundation
import Observation
import SwiftUI
import XAirKit

/// App-level state: the mixer session, an optional in-app simulator, selection and preferences.
@MainActor
@Observable
final class AppModel {
    let session: MixerSession
    private(set) var simulator: MixerSimulator?
    private(set) var simulatorModel: String?

    var selectedStrip = 0 { didSet { if (0..<32).contains(selectedStrip) { session.selectedChannel = selectedStrip } } }
    var mixerLayer: MixerLayer = .inputs
    /// Sends-on-fader target (0..5 bus, 6..9 FX send) or nil for main mix.
    var sendsOnFader: Int?
    var selectedTab: AppTab = .mixer
    var selectedFXSlot = 1
    var channelSection: ChannelSection = .eq
    var showingRTA = false
    var requestedSetupPage: SetupPage?
    var compactNavigation = false
    func openTab(_ tab: AppTab) {
        if compactNavigation, [.setup, .meters, .routing].contains(tab) {
            toolsPage = tab
            selectedTab = .tools
        } else { selectedTab = tab }
    }

    func stepFader(up: Bool) {
        let base = Self.base(of: selectedStrip)
        let sending = selectedStrip < 21 && sendsOnFader != nil
        let path: String
        if sending, let send = sendsOnFader { path = base + String(format: "/mix/%02d/level", send + 1) }
        else { path = base + (selectedStrip >= 32 ? "/fader" : "/mix/fader") }
        let step = sending ? (fineFaders ? 1 : 2) : (fineFaders ? 6 : 12)
        session.set(path, index: store.index(path) + (up ? step : -step))
    }
    /// Page pushed inside the iPhone Tools tab.
    var toolsPage: AppTab?
    var alert: AppAlert?
    var clipboard: String?
    var recentDevices: [MixerDevice] = []
    var userLayer1: [Int] = Array(0..<8)
    var userLayer2: [Int] = Array(8..<16)
    var confirmPopups = true
    /// Offline editing with a chosen model (no mixer connected).
    var offlineEditing = false
    /// GUI preferences from the original: exclusive solo, follow last solo.
    var exclusiveSolo = false
    var followSolo = false
    var invertMutes = false { didSet { defaults.set(invertMutes, forKey: "invertMutes") } }
    var fineFaders = false { didSet { defaults.set(fineFaders, forKey: "fineFaders") } }
    var selectOnFader = false { didSet { defaults.set(selectOnFader, forKey: "selectOnFader") } }
    /// Original "Auto Connect": connect to the last mixer at launch.
    var autoConnect = false

    private let defaults = UserDefaults.standard

    init() {
        session = MixerSession(transport: UDPSocketTransport())
        if let data = defaults.data(forKey: "recentDevices"), let list = try? JSONDecoder().decode([MixerDevice].self, from: data) {
            recentDevices = list
        }
        session.syncDirection = SyncDirection(rawValue: defaults.integer(forKey: "syncDirection")) ?? .mixerToApp
        session.autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        session.meterHalfRate = defaults.bool(forKey: "meterHalfRate")
        session.rtaHalfRate = defaults.bool(forKey: "rtaHalfRate")
        confirmPopups = defaults.object(forKey: "confirmPopups") as? Bool ?? true
        exclusiveSolo = defaults.bool(forKey: "exclusiveSolo")
        followSolo = defaults.bool(forKey: "followSolo")
        invertMutes = defaults.bool(forKey: "invertMutes")
        fineFaders = defaults.bool(forKey: "fineFaders")
        selectOnFader = defaults.bool(forKey: "selectOnFader")
        session.linkSendTaps = defaults.object(forKey: "linkSendTaps") as? Bool ?? true
        autoConnect = defaults.bool(forKey: "autoConnect")
        if let u1 = defaults.array(forKey: "userLayer1") as? [Int] { userLayer1 = u1 }
        if let u2 = defaults.array(forKey: "userLayer2") as? [Int] { userLayer2 = u2 }
        do { try session.start() } catch { alert = AppAlert(title: "Network unavailable", message: "\(error)") }
        let launchArgs = ProcessInfo.processInfo.arguments
        if autoConnect, let last = recentDevices.first, !launchArgs.contains("-simulator"), !launchArgs.contains("-connect") {
            session.connect(to: last)
        }
    }

    var store: ParameterStore { session.store }
    var model: MixerModel { session.model ?? .xr18 }
    var isOnline: Bool { session.state == .online }

    func savePreferences() {
        defaults.set(session.syncDirection.rawValue, forKey: "syncDirection")
        defaults.set(session.autoReconnect, forKey: "autoReconnect")
        defaults.set(session.meterHalfRate, forKey: "meterHalfRate")
        defaults.set(session.rtaHalfRate, forKey: "rtaHalfRate")
        defaults.set(confirmPopups, forKey: "confirmPopups")
        defaults.set(exclusiveSolo, forKey: "exclusiveSolo")
        defaults.set(session.linkSendTaps, forKey: "linkSendTaps")
        defaults.set(followSolo, forKey: "followSolo")
        defaults.set(autoConnect, forKey: "autoConnect")
        defaults.set(userLayer1, forKey: "userLayer1")
        defaults.set(userLayer2, forKey: "userLayer2")
    }

    // MARK: Connection

    func connect(_ device: MixerDevice) {
        session.connect(to: device)
    }

    func connect(ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        session.connect(ip: trimmed)
    }

    func rememberConnectedMixer() {
        guard isOnline, simulator == nil, let d = session.device else { return }
        recentDevices.removeAll { $0.ip == d.ip }
        recentDevices.insert(d, at: 0)
        recentDevices = Array(recentDevices.prefix(6))
        if let data = try? JSONEncoder().encode(recentDevices) { defaults.set(data, forKey: "recentDevices") }
    }

    /// Each in-app mixer owns a private loopback port, including across simulator devices.
    func startSimulator(model: String) {
        stopSimulator()
        let server = UDPSocketTransport(bindHost: "127.0.0.1", bindPort: 0)
        let sim = MixerSimulator(transport: server, identity: .init(ip: "127.0.0.1", name: "\(model)-Simulator", model: model, firmware: "1.22"))
        do {
            try sim.start(autoTick: true)
            simulator = sim
            simulatorModel = model
            session.connect(ip: "127.0.0.1", port: server.localPort)
        } catch {
            alert = AppAlert(title: "Simulator could not start", message: error.localizedDescription)
        }
    }

    func stopSimulator() {
        simulator?.stop()
        simulator = nil
        simulatorModel = nil
    }

    func disconnect() {
        session.disconnect()
        stopSimulator()
        offlineEditing = false
    }

    func startOffline(model: MixerModel) {
        stopSimulator()
        session.beginOffline(model: model)
        offlineEditing = true
    }

    /// Leaves offline editing and connects; App -> Mixer sync pushes the offline edits.
    func connectFromOffline(ip: String) {
        offlineEditing = false
        session.connect(ip: ip, direction: .appToMixer)
    }

    /// Solo with the original's Exclusive Solo / Follow Solo preferences.
    func toggleSolo(strip: Int) {
        guard strip < 32 else { return }
        let path = String(format: "/-stat/solosw/%02d", strip + 1)
        let turningOn = !store.bool(path)
        if turningOn && exclusiveSolo {
            for i in 1...32 where i != strip + 1 && store.bool(String(format: "/-stat/solosw/%02d", i)) {
                session.set(String(format: "/-stat/solosw/%02d", i), index: 0)
            }
        }
        session.set(path, index: turningOn ? 1 : 0)
        if turningOn && followSolo { selectedStrip = strip }
    }

    // MARK: Strips

    /// Strip index -> node base: 0..15 ch, 16 aux, 17..20 fx returns, 21..26 bus, 27..30 fx sends, 31 LR, 32..35 DCA.
    static func base(of strip: Int) -> String {
        if strip >= 32 { return "/dca/\(strip - 31)" }
        return SceneFiles.channelBase(strip)
    }

    func stripName(_ strip: Int) -> String {
        let base = Self.base(of: strip)
        let n = store.string(base + "/config/name")
        if !n.isEmpty { return n }
        return Self.defaultName(strip)
    }

    static func defaultName(_ strip: Int) -> String {
        switch strip {
        case 0..<16: String(format: "Ch %02d", strip + 1)
        case 16: "Aux"
        case 17..<21: "FX \(strip - 16)"
        case 21..<27: "Bus \(strip - 20)"
        case 27..<31: "FX Snd \(strip - 26)"
        case 31: "Main LR"
        default: "DCA \(strip - 31)"
        }
    }

    func stripColor(_ strip: Int) -> Int { store.index(Self.base(of: strip) + "/config/color") }

    func visibleStrips(for layer: MixerLayer) -> [Int] {
        switch layer {
        case .inputs: Array(0..<model.channelCount)
        case .returns: Array(16..<21)
        case .buses: Array(21..<31)
        case .dca: Array(32..<36)
        case .user1: userLayer1.filter { $0 < model.channelCount || $0 >= 16 }
        case .user2: userLayer2.filter { $0 < model.channelCount || $0 >= 16 }
        case .dcaSpill(let d):
            (0..<21).filter { s in
                let grp = Self.base(of: s) + "/grp/dca"
                return store.index(grp) & (1 << d) != 0
            }
        }
    }

    // MARK: Files

    @discardableResult
    func fileURL(_ result: Result<URL, Error>) -> URL? {
        switch result {
        case .success(let url): return url
        case .failure(let error):
            let cause = error as NSError
            if cause.domain != NSCocoaErrorDomain || cause.code != NSUserCancelledError {
                alert = AppAlert(title: "File operation failed", message: error.localizedDescription)
            }
            return nil
        }
    }

    func importScene(_ text: String) {
        let msgs = SceneFiles.importLines(text, into: store)
        guard !msgs.isEmpty else { alert = AppAlert(title: "No scene settings found", message: "Choose a mixer scene with recognised parameter values."); return }
        session.pushNodes(msgs)
    }

    func copyStrip(_ strip: Int) {
        clipboard = SceneFiles.copyChannel(store: store, channel: Self.base(of: strip))
    }

    func paste(into strip: Int, scopes: Set<PasteScope>) {
        guard let clipboard else { return }
        session.pushNodes(SceneFiles.paste(clipboard, into: store, channel: Self.base(of: strip), scopes: scopes))
    }
}

enum MixerLayer: Hashable, Identifiable {
    case inputs, returns, buses, dca, user1, user2, dcaSpill(Int)
    var id: String { title }
    var title: String {
        switch self {
        case .inputs: "Inputs"
        case .returns: "Aux / FX"
        case .buses: "Buses"
        case .dca: "DCA"
        case .user1: "User 1"
        case .user2: "User 2"
        case .dcaSpill(let d): "DCA \(d + 1) Spill"
        }
    }
    static let primary: [MixerLayer] = [.inputs, .returns, .buses, .dca, .user1, .user2]
}

enum AppTab: String, Hashable, CaseIterable {
    case mixer, channel, effects, routing, scenes, meters, setup, tools
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
