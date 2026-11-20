import Foundation
import Testing
@testable import XAirKit

@MainActor
final class Rig {
    let link = LoopbackLink()
    let sim: MixerSimulator
    let session: MixerSession
    var clock = ContinuousClock.now

    /// Advances the session's injected clock and runs its timers.
    func advance(_ d: Duration) {
        clock += d
        session.tick(now: clock)
    }

    init(model: String = "XR18", firmware: String = "1.22", autoTickSession: Bool = false) throws {
        sim = MixerSimulator(transport: link.mixerEndpoint,
                             identity: .init(ip: link.mixerHost, name: "SIM-\(model)", model: model, firmware: firmware))
        try sim.start(autoTick: false)
        session = MixerSession(transport: link.clientEndpoint)
        try session.start(autoTick: autoTickSession)
        session.now = { [unowned self] in self.clock }
    }

    var device: MixerDevice { MixerDevice(ip: link.mixerHost, name: sim.identity.name, modelString: sim.identity.model, firmware: sim.identity.firmware) }

    /// Polls until `cond` holds (both sides are asynchronous queues).
    func until(_ what: String = "", timeout: Double = 10, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { Issue.record("timeout waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func connectAndSync(_ dir: SyncDirection = .mixerToApp) async throws {
        session.connect(to: device, direction: dir)
        try await until("online", timeout: 20) { session.state == .online }
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(40)) }
}

@Suite("Session against the simulator", .serialized)
@MainActor
struct SessionTests {
    @Test func discoveryOverLoopback() async throws {
        let r = try Rig()
        r.session.discover(targets: ["192.168.1.1", "255.255.255.255"])
        try await r.until("xinfo") { !r.session.discovered.isEmpty }
        let d = try #require(r.session.discovered.first)
        #expect(d.modelString == "XR18" && d.name == "SIM-XR18" && d.firmware == "1.22")
        #expect(r.sim.receivedAddresses.contains("/xinfo(raw)"))
    }

    @Test func connectSyncsEveryNodeFromTheMixer() async throws {
        let r = try Rig()
        r.sim.externalSet("/ch/03/config/name", string: "Vocal")
        r.sim.externalSet("/ch/03/mix/fader", index: 600)
        try await r.connectAndSync()
        #expect(r.session.model == .xr18)
        #expect(r.session.syncFailures.isEmpty)
        #expect(r.session.store.string("/ch/03/config/name") == "Vocal")
        #expect(r.session.store.index("/ch/03/mix/fader") == 600)
        #expect(r.session.store.string("/-prefs/name") == "SIM-XR18")
        // Sync order: /status, prefs/stat/snap paths, then the 693 node paths, setclock, meters.
        let rx = r.sim.receivedAddresses
        #expect(rx.first == "/status")
        #expect(rx.contains("/-prefs/name") && rx.contains("/fx/4/par"))
        #expect(rx.contains("/-action/setclock"))
        #expect(rx.filter { $0 == "/batchsubscribe" }.count == 2)
        #expect(Set(r.sim.meterSubscriptionIDs) == ["meters/1", "meters/6"])
        // Every received value must equal the mixer's
        for p in ["/ch/01/eq/2/f", "/bus/1/eq/1/type", "/routing/aux/03/src", "/fx/2/par/04", "/headamp/05/gain"] {
            #expect(r.session.store.index(p) == r.sim.value(p), "\(p)")
        }
    }

    @Test func userEditReachesMixerAndExternalChangeReachesApp() async throws {
        let r = try Rig()
        try await r.connectAndSync()
        r.session.set("/ch/01/mix/fader", value: -10)
        try await r.until("fader on mixer") { r.sim.value("/ch/01/mix/fader") == r.session.store.index("/ch/01/mix/fader") }
        #expect(abs(r.session.store.physical("/ch/01/mix/fader") + 10) < 0.1)
        r.session.set("/ch/02/config/name", string: "Guitar")
        try await r.until("name on mixer") { r.sim.stringValue("/ch/02/config/name") == "Guitar" }
        r.session.toggle("/ch/04/mix/on")
        try await r.until("mute") { r.sim.value("/ch/04/mix/on") == 0 }
        // Another client changes the mixer: /xremotenfb registration delivers it.
        r.advance(.seconds(3)) // sends /xremotenfb
        try await r.until("remote registered") { r.sim.remoteClientCount == 1 }
        r.sim.externalSet("/bus/2/mix/fader", index: 333)
        try await r.until("external change") { r.session.store.index("/bus/2/mix/fader") == 333 }
    }

    @Test func metersSubscribeRenewAndDecode() async throws {
        let r = try Rig()
        try await r.connectAndSync()
        for _ in 0..<4 { r.sim.tick() }
        try await r.until("meters") { r.session.meters.blocks[1].count == 40 }
        #expect(r.session.meters.blocks[6].count == 39)
        // Renew cadence: 5 renews, then a full /batchsubscribe (OscSub::run).
        for _ in 0..<6 { r.advance(.milliseconds(2100)); try await r.settle(); r.sim.tick() }
        try await r.settle()
        let rx = r.sim.receivedAddresses
        #expect(rx.filter { $0 == "/renew" }.count == 10)       // 5 per subscription
        #expect(rx.filter { $0 == "/batchsubscribe" }.count == 4) // 2 initial + 2 resubscribes
        r.session.subscribe(meterBlock: 4)
        try await r.until("rta subscribed") { r.sim.meterSubscriptionIDs.contains("meters/4") }
        r.sim.tick()
        try await r.until("rta") { r.session.meters.blocks[4].count == 100 }
        r.session.unsubscribe(meterBlock: 4)
        try await r.until("unsubscribed") { !r.sim.meterSubscriptionIDs.contains("meters/4") }
    }

    @Test func linkLossTriggersAutoReconnectAndResync() async throws {
        let r = try Rig()
        try await r.connectAndSync()
        r.link.mixerReachable = false
        r.advance(.seconds(11))
        #expect(r.session.state == .reconnecting(r.link.mixerHost))
        r.sim.externalSet("/ch/07/mix/fader", index: 100) // changed while we were away
        r.link.mixerReachable = true
        r.advance(.seconds(3))                             // keepalive -> /xinfo -> /status -> sync
        try await r.until("reconnected", timeout: 20) { r.session.state == .online }
        #expect(r.session.store.index("/ch/07/mix/fader") == 100)
    }

    @Test func connectFailsCleanlyWhenMixerSilent() async throws {
        let r = try Rig()
        r.link.mixerReachable = false
        r.session.connect(to: r.device)
        for _ in 0..<6 { r.advance(.seconds(1.1)) }
        if case .failed(let msg) = r.session.state { #expect(msg.contains("No response")) } else { Issue.record("expected failure, got \(r.session.state)") }
    }

    @Test func incompatibleFirmwareIsRejected() throws {
        let r = try Rig(firmware: "1.08")
        r.session.connect(to: r.device)
        if case .failed(let msg) = r.session.state { #expect(msg.contains("Incompatible")) } else { Issue.record("expected failure") }
    }

    @Test func fxTypeChangeRetypesParameters() async throws {
        let r = try Rig()
        try await r.connectAndSync()
        let dly = try #require(r.session.schema.fxTypes.firstIndex(of: "DLY"))
        r.session.set("/fx/1/type", index: dly)
        #expect(r.session.store.fxTypeName(slot: 1) == "DLY")
        #expect(r.session.store.spec("/fx/1/par/03")?.enumItems == ["ST", "X", "M"])
        try await r.until("fx type on mixer") { r.sim.value("/fx/1/type") == dly }
        // The mixer reset the parameters; read-back after the edit picks them up.
        r.advance(.seconds(1))
        try await r.until("fx par read back") { r.session.store.index("/fx/1/par/02") == r.sim.value("/fx/1/par/02") }
    }

    @Test func channelLinkMirrorsAllowedParameters() async throws {
        let r = try Rig()
        try await r.connectAndSync()
        r.session.set("/config/chlink/1-2", index: 1)          // also copies ch1 -> ch2
        r.session.set("/config/linkcfg/eq", index: 1)
        r.session.set("/ch/01/eq/1/g", value: 6)
        try await r.until("mirrored eq") { r.sim.value("/ch/02/eq/1/g") == r.session.store.index("/ch/01/eq/1/g") }
        let pan2 = r.session.store.index("/ch/02/mix/pan")
        r.session.set("/ch/01/mix/pan", value: -50)           // pan is link-excluded (Cparam+0x69)
        try await r.settle()
        #expect(r.session.store.index("/ch/02/mix/pan") == pan2)
        r.session.set("/config/linkcfg/fdrmute", index: 0)
        let f2 = r.session.store.index("/ch/02/mix/fader")
        r.session.set("/ch/01/mix/fader", value: -20)          // gated off by linkcfg/fdrmute
        try await r.settle()
        #expect(r.session.store.index("/ch/02/mix/fader") == f2)
    }

    @Test func snapshotSaveAndLoad() async throws {
        let r = try Rig()
        try await r.connectAndSync()
        r.session.set("/-snap/name", string: "Verse")
        r.session.set("/ch/05/mix/fader", index: 500)
        try await r.until("fader") { r.sim.value("/ch/05/mix/fader") == 500 }
        r.session.command("/-snap/save", [.int(3)])
        try await r.until("saved") { r.sim.stringValue("/-snap/03/name") == "Verse" }
        r.session.set("/ch/05/mix/fader", index: 10)
        try await r.until("changed") { r.sim.value("/ch/05/mix/fader") == 10 }
        r.session.command("/-snap/load", [.int(3)])
        r.advance(.seconds(3))
        try await r.until("recalled") { r.sim.value("/ch/05/mix/fader") == 500 }
        r.session.resync()
        try await r.until("resynced", timeout: 20) { r.session.state == .online && r.session.store.index("/ch/05/mix/fader") == 500 }
    }

    @Test func pushSyncSendsAppStateThenVerifies() async throws {
        let r = try Rig()
        r.session.store.store("/ch/09/config/name", string: "FromApp")
        r.session.store.store("/ch/09/mix/fader", index: 444)
        try await r.connectAndSync(.appToMixer)
        #expect(r.sim.stringValue("/ch/09/config/name") == "FromApp")
        #expect(r.sim.value("/ch/09/mix/fader") == 444)
    }

    @Test func syncSurvivesPacketLossWithRetries() async throws {
        let r = try Rig()
        r.link.dropEvery = 7
        r.session.connect(to: r.device)
        let deadline = Date().addingTimeInterval(30)
        while r.session.state != .online && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
            r.advance(.milliseconds(600))
        }
        #expect(r.session.state == .online)
        #expect(r.session.syncFailures.isEmpty)
    }

    @Test func xr12ModelSyncsRecorderAndUSB() async throws {
        let r = try Rig(model: "XR12")
        try await r.connectAndSync()
        #expect(r.session.model == .xr12)
        #expect(r.session.store.string("/-stat/usb/002/name") == "R_20261107-120000.wav")
        #expect(r.sim.receivedAddresses.contains("/-stat/tape"))
        r.session.set("/-stat/tape/state", index: 2) // PLAY
        try await r.until("play") { r.sim.value("/-stat/tape/state") == 2 }
    }

    @Test func realUDPEndToEnd() async throws {
        let server = UDPSocketTransport(bindHost: "127.0.0.1", bindPort: 0)
        let sim = MixerSimulator(transport: server, identity: .init(ip: "127.0.0.1"))
        try sim.start(autoTick: true)
        defer { sim.stop() }
        let session = MixerSession(transport: UDPSocketTransport(), port: server.localPort)
        try session.start(autoTick: true)
        defer { session.shutdown() }
        session.connect(ip: "127.0.0.1")
        let ok = await session.waitUntilOnline(timeout: .seconds(30))
        #expect(ok)
        session.set("/lr/mix/fader", index: 700)
        let deadline = Date().addingTimeInterval(5)
        while sim.value("/lr/mix/fader") != 700 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sim.value("/lr/mix/fader") == 700)
    }
}

@Suite("Offline editing")
@MainActor
struct OfflineTests {
    @Test func offlineEditsArePushedOnConnect() async throws {
        let r = try Rig()
        r.session.beginOffline(model: .xr16)
        #expect(r.session.model == .xr16)
        #expect(r.session.store.display("/ch/01/eq/2/f") == "496.6")   // default scene loaded
        r.session.set("/ch/12/config/name", string: "Offline")          // stays local while offline
        #expect(r.sim.stringValue("/ch/12/config/name") != "Offline")
        try await r.connectAndSync(.appToMixer)
        #expect(r.sim.stringValue("/ch/12/config/name") == "Offline")
    }
}
