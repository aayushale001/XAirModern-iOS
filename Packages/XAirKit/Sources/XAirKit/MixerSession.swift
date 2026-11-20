import Foundation
import Observation

public enum SyncDirection: Int, Sendable, Codable, CaseIterable {
    /// Mixer -> app (the original's default, "Synchronize (recommended)").
    case mixerToApp = 0
    /// App -> mixer (push the app's current state, then verify).
    case appToMixer = 1
}

public enum ConnectionState: Equatable, Sendable {
    case offline
    case connecting(String)
    case syncing
    case online
    case reconnecting(String)
    case failed(String)

    public var isConnected: Bool { self == .online || self == .syncing }
}

/// Timing constants taken from OscSub::run / OscCom::run (PROTOCOL.md §5).
public struct SessionTiming: Sendable {
    public var tick: Duration = .milliseconds(50)              // OscSub::run work period
    public var keepalive: Duration = .milliseconds(2000)       // /xremotenfb or /xinfo
    public var renew: Duration = .milliseconds(2000)           // /renew per meter subscription
    public var renewsBeforeResubscribe = 5                     // state 1..5 renew, 6 -> /batchsubscribe
    public var linkTimeout: Duration = .seconds(10)            // no data -> lost
    public var nodeRetry: Duration = .milliseconds(500)        // node request resend
    public var nodeMaxAttempts = 8                             // bounded (original: unbounded)
    public var statusRetry: Duration = .milliseconds(1000)
    public var statusMaxAttempts = 5
    public var verifyDelay: Duration = .milliseconds(400)      // read-back after an edit
    public var requestWindow = 4                                // node requests in flight
    public init() {}
}

@MainActor
@Observable
public final class MixerSession {
    public let store: ParameterStore
    public let meters: MeterStore
    public let schema: XAirSchema

    public private(set) var state: ConnectionState = .offline
    public private(set) var device: MixerDevice?
    public private(set) var model: MixerModel?
    public private(set) var discovered: [MixerDevice] = []
    public private(set) var syncProgress: Double = 0
    public private(set) var syncFailures: [String] = []
    public private(set) var lastError: String?
    public private(set) var stats = Stats()

    public struct Stats: Sendable, Equatable {
        public var packetsIn = 0, packetsOut = 0, decodeErrors = 0, ignoredForeign = 0
    }

    public var syncDirection: SyncDirection = .mixerToApp
    public var autoReconnect = true
    /// `/-localprefs/updrate` equivalents: 50% meter / RTA update rate.
    public var meterHalfRate = false { didSet { if meterHalfRate != oldValue { resubscribeAll() } } }
    public var rtaHalfRate = false { didSet { if rtaHalfRate != oldValue { resubscribeAll() } } }
    /// `chan/selidx` — selected channel; sent as the two middle ints of /batchsubscribe.
    public var selectedChannel = 0 { didSet { if selectedChannel != oldValue { resubscribeAll() } } }

    /// UDP port of the mixer (10024 on hardware; the simulator may use another).
    public private(set) var port: UInt16
    public let defaultPort: UInt16
    public var timing = SessionTiming()
    /// Time source for every timer (injectable for deterministic tests).
    public var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }

    private let transport: DatagramTransport
    private var host: String?
    private var started = false
    private var tickTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var inbox: AsyncStream<Datagram>.Continuation?

    private var lastRx: ContinuousClock.Instant?
    private var lastKeepalive: ContinuousClock.Instant?
    private var statusSentAt: ContinuousClock.Instant?
    private var statusAttempts = 0
    private var reconnectDevice: MixerDevice?

    private struct MeterSub { var block: Int; var state: Int; var lastSent: ContinuousClock.Instant }
    private var meterSubs: [Int: MeterSub] = [:]

    private struct Pending { var write: OSCMessage?; var message: OSCMessage; var sentAt: ContinuousClock.Instant; var attempts: Int; var onDone: ((Bool) -> Void)? }
    private var pending: [String: Pending] = [:]
    private var requestQueue: [(query: OSCMessage, write: OSCMessage?, completion: ((Bool) -> Void)?)] = []
    private var viewMeters: [UUID: Set<Int>] = [:]
    private var activeSyncDirection: SyncDirection = .mixerToApp
    public var linkSendTaps = true
    public internal(set) var directoryLoading = false
    public internal(set) var directoryError: String?
    internal var directoryGeneration = 0

    private var syncTotal = 0
    private var syncDone = 0
    private var syncPhase: SyncPhase = .idle
    private enum SyncPhase { case idle, prefs, main, push, verify, usb, finishing }

    private var verifyDue: [String: ContinuousClock.Instant] = [:]
    private var onlineContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(transport: DatagramTransport, schema: XAirSchema = .shared, port: UInt16 = 10024) {
        self.transport = transport
        self.schema = schema
        self.store = ParameterStore(schema: schema)
        self.meters = MeterStore()
        self.port = port
        self.defaultPort = port
    }

    // MARK: Lifecycle

    /// Starts receiving; `autoTick: false` lets tests drive timers with `tick(now:)`.
    public func start(autoTick: Bool = true) throws {
        guard !started else { return }
        let (stream, cont) = AsyncStream<Datagram>.makeStream(bufferingPolicy: .bufferingNewest(2048))
        inbox = cont
        try transport.start { dg in cont.yield(dg) }
        started = true
        receiveTask = Task { @MainActor [weak self] in
            for await dg in stream { self?.receive(dg) }
        }
        if autoTick {
            tickTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.timing.tick ?? .milliseconds(50))
                    if let self { self.tick(now: self.now()) }
                }
            }
        }
    }

    public func shutdown() {
        disconnect()
        tickTask?.cancel(); receiveTask?.cancel()
        inbox?.finish()
        transport.stop()
        started = false
    }

    // MARK: Discovery

    /// Raw 6-byte `/xinfo` probes to 192.168.1.1, subnet broadcasts and 255.255.255.255 (ConnectPage::findDevices).
    public func discover(targets: [String]? = nil) {
        discovered.removeAll()
        let probe = Data("/xinfo".utf8)
        for t in targets ?? NetworkInterfaces.discoveryTargets() {
            do { try transport.send(probe, to: t, port: port); stats.packetsOut += 1 }
            catch { lastError = "Discovery send to \(t) failed: \(error)" }
        }
    }

    /// Manual IP: a standard OSC `/xinfo` to one host. Works without broadcast entitlement.
    public func probe(ip: String) {
        guard NetworkInterfaces.isValidIPv4(ip) else { lastError = "\(ip) is not a valid IPv4 address"; return }
        send(OSCMessage("/xinfo"), to: ip)
    }

    // MARK: Connect / disconnect

    public func connect(to device: MixerDevice, direction: SyncDirection? = nil, port: UInt16? = nil) {
        if let direction { syncDirection = direction }
        if let port { self.port = port }
        guard device.model != nil else {
            state = .failed("Unsupported mixer model \(device.modelString)")
            return
        }
        guard device.isFirmwareCompatible else {
            // ConnectPage::checkAndConnectDevice: "Incompatible Mixer Firmware!"
            state = .failed("Incompatible mixer firmware \(device.firmware). Please update to the latest version.")
            return
        }
        resetLink()
        self.device = device
        host = device.ip
        reconnectDevice = device
        state = .connecting(device.ip)
        sendStatus()
    }

    /// Connect by IP when no `/xinfo` reply has been seen yet: probe, then connect on reply.
    public func connect(ip: String, direction: SyncDirection? = nil, port: UInt16? = nil) {
        if let direction { syncDirection = direction }
        self.port = port ?? defaultPort
        guard NetworkInterfaces.isValidIPv4(ip) else { state = .failed("\(ip) is not a valid IPv4 address"); return }
        resetLink()
        device = nil
        host = ip
        reconnectDevice = MixerDevice(ip: ip, name: "", modelString: "", firmware: "")
        state = .connecting(ip)
        send(OSCMessage("/xinfo"), to: ip)
        statusSentAt = now()
        statusAttempts = 1
    }

    /// Offline editing ("Offline Mixer Model"): no connection; edits stay local until pushed.
    public func beginOffline(model m: MixerModel) {
        disconnect()
        model = m
        store.setModel(m)
        store.loadDefaults()
        syncDirection = .appToMixer
    }

    public func disconnect() {
        if state.isConnected {
            for b in meterSubs.keys { send(OSCMessage("/unsubscribe", [.string(schema.meterIds[b])])) }
        }
        resetLink()
        reconnectDevice = nil
        host = nil
        device = nil
        state = .offline
        port = defaultPort
    }

    private func resetLink() {
        directoryGeneration &+= 1
        directoryLoading = false
        directoryError = nil
        meterSubs.removeAll()
        pending.removeAll()
        requestQueue.removeAll()
        verifyDue.removeAll()
        syncPhase = .idle
        lastRx = nil
        lastKeepalive = nil
        statusSentAt = nil
        statusAttempts = 0
        meters.reset()
    }

    private func sendStatus() {
        guard let host else { return }
        send(OSCMessage("/status"), to: host)
        statusSentAt = now()
        statusAttempts += 1
    }

    /// Waits until online or failed (for tests and scripted flows).
    public func waitUntilOnline(timeout: Duration = .seconds(30)) async -> Bool {
        if state == .online { return true }
        return await withCheckedContinuation { c in
            let ticket = UUID()
            onlineContinuations[ticket] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.onlineContinuations.removeValue(forKey: ticket)?.resume(returning: false)
            }
        }
    }

    private func resumeOnline(_ ok: Bool) {
        let cs = onlineContinuations
        onlineContinuations.removeAll()
        cs.values.forEach { $0.resume(returning: ok) }
    }

    // MARK: Sending

    public func send(_ message: OSCMessage, to explicitHost: String? = nil) {
        guard let h = explicitHost ?? host else { return }
        do {
            try transport.send(OSCCodec.encode(message), to: h, port: port)
            stats.packetsOut += 1
        } catch {
            lastError = "Send failed: \(error)"
        }
    }

    /// User edit: update local state, send the parameter (Cparam::getOscMessage),
    /// mirror to a linked partner (Cnode::copyLinkCh rules), schedule read-back.
    public func set(_ path: String, index: Int) {
        guard let spec = store.spec(path) else { return }
        let idx = spec.clamp(index)
        let changed = store.store(path, index: idx)
        if state.isConnected, let arg = store.oscArgument(path) { send(OSCMessage(path, [arg])) }
        if changed {
            mirrorLinked(path: path, index: idx, string: nil)
            if path.oscParent == "/config/mute", let group = Int(path.oscLastComponent), (1...4).contains(group) {
                updateSoftMutes(group: group, engaged: idx != 0)
            }
        }
        afterLocalEdit(path)
    }

    public func set(_ path: String, string: String) {
        guard let spec = store.spec(path), case .string(let maxLen) = spec.kind else { return }
        let s = String(string.prefix(maxLen))
        let changed = store.store(path, string: s)
        if state.isConnected { send(OSCMessage(path, [.string(s)])) }
        if changed { mirrorLinked(path: path, index: nil, string: s) }
        afterLocalEdit(path)
    }

    public func set(_ path: String, value: Float) {
        guard let spec = store.spec(path) else { return }
        set(path, index: spec.index(forValue: value))
    }

    public func toggle(_ path: String) { set(path, index: store.bool(path) ? 0 : 1) }

    /// Pushes node messages produced by a scene/preset import, then reads each node back.
    public func pushNodes(_ messages: [OSCMessage]) {
        guard state == .online else { return }
        for message in messages {
            enqueue(OSCMessage(message.address), write: message) { [weak self] ok in
                if !ok { self?.lastError = "The mixer did not confirm " + message.address }
            }
        }
    }

    /// Fire-and-forget command (e.g. `/-snap/load ,i 3`).
    public func command(_ path: String, _ args: [OSCArgument]) {
        guard state.isConnected else { return }
        send(OSCMessage(path, args))
    }

    private func afterLocalEdit(_ path: String) {
        if path.hasPrefix("/config/chlink/") || path.hasPrefix("/config/buslink/"), store.bool(path) {
            copyLink(pairKey: path)
        }
        guard state == .online else { return }
        let node = store.isNode(path) ? path : path.oscParent
        verifyDue[node] = now() + timing.verifyDelay
        // FX type change retypes /fx/N/par: read the new parameter set back.
        if let slot = XAirSchema.fxSlot(of: path) ?? fxTypeSlot(path) {
            verifyDue["/fx/\(slot)/par"] = now() + timing.verifyDelay
        }
    }

    private func fxTypeSlot(_ path: String) -> Int? {
        let p = path.split(separator: "/")
        guard p.count == 3, p[0] == "fx", p[2] == "type", let n = Int(p[1]) else { return nil }
        return n
    }

    // MARK: Node requests (OscCom::send_node_request — the node path with no arguments)

    public func requestNode(_ path: String, completion: ((Bool) -> Void)? = nil) {
        enqueue(OSCMessage(path), completion)
    }

    private func enqueue(_ m: OSCMessage, write: OSCMessage? = nil, _ completion: ((Bool) -> Void)?) {
        requestQueue.append((m, write, completion))
        pumpRequests(now: now())
    }

    private func pumpRequests(now: ContinuousClock.Instant) {
        while pending.count < timing.requestWindow, !requestQueue.isEmpty {
            let next = requestQueue[0]
            // Keep successive writes to the same address in file order.
            if next.write != nil, pending[next.query.address] != nil { return }
            let (m, write, done) = requestQueue.removeFirst()
            if pending[m.address] != nil {
                // coalesce with the in-flight request for the same path
                let prev = pending[m.address]!.onDone
                pending[m.address]!.onDone = { ok in prev?(ok); done?(ok) }
                continue
            }
            pending[m.address] = Pending(write: write, message: m, sentAt: now, attempts: 1, onDone: done)
            if let write { send(write) }
            send(m)
        }
    }

    private func resolve(_ path: String, ok: Bool) {
        guard let p = pending.removeValue(forKey: path) else { return }
        p.onDone?(ok)
        pumpRequests(now: now())
    }

    // MARK: Sync (OscCom::run)

    private func beginSync(direction: SyncDirection? = nil) {
        guard let model else { return }
        activeSyncDirection = direction ?? syncDirection
        state = .syncing
        syncFailures.removeAll()
        syncProgress = 0
        let prefs = Array(schema.prefStatSnapPaths.prefix(model.prefStatSnapCount))
        let main = schema.syncPaths
        syncTotal = prefs.count + main.count
        syncDone = 0
        syncPhase = .prefs
        for p in prefs { enqueue(OSCMessage(p)) { [weak self] ok in self?.syncStep(p, ok) } }
    }

    private func syncStep(_ path: String, _ ok: Bool) {
        if !ok { syncFailures.append(path) }
        syncDone += 1
        syncProgress = syncTotal > 0 ? min(1, Double(syncDone) / Double(syncTotal)) : 1
        guard pending.isEmpty, requestQueue.isEmpty else { return }
        advanceSync()
    }

    private func advanceSync() {
        switch syncPhase {
        case .prefs:
            if activeSyncDirection == .appToMixer {
                syncPhase = .push
                for p in schema.syncPaths {
                    enqueue(OSCMessage(p), write: store.nodeMessage(p)) { [weak self] ok in self?.syncStep(p, ok) }
                }
            } else {
                syncPhase = .main
                for p in schema.syncPaths { enqueue(OSCMessage(p)) { [weak self] ok in self?.syncStep(p, ok) } }
            }
        case .main, .push:
            if model?.hasUSBRecorder == true {
                syncPhase = .usb
                let count = store.index("/-stat/usb/count")
                let paths = schema.usbDirPaths.prefix(max(0, min(count, schema.usbDirPaths.count)))
                if paths.isEmpty { advanceSync(); return }
                syncTotal += paths.count
                for p in paths { enqueue(OSCMessage(p)) { [weak self] ok in self?.syncStep(p, ok) } }
            } else {
                syncPhase = .usb
                advanceSync()
            }
        case .usb:
            syncPhase = .finishing
            finishSync()
        default:
            break
        }
    }

    private func finishSync() {
        // OscCom::run tail: set mixer clock, then subscribe /meters/1 and /meters/6.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        let clock = f.string(from: Date())
        store.store("/-action/setclock", string: clock)
        send(OSCMessage("/-action/setclock", [.string(clock)]))
        for block in desiredMeterBlocks.sorted() { subscribe(meterBlock: block) }
        syncPhase = .idle
        syncProgress = 1
        state = .online
        resumeOnline(true)
    }

    /// Full resync from the mixer (used after snapshot recall and on demand).
    public func resync() {
        guard state.isConnected else { return }
        guard state == .online else { return }
        beginSync(direction: .mixerToApp)
    }

    // MARK: Meters (OscSub::send_metersrequest)

    private var desiredMeterBlocks: Set<Int> {
        viewMeters.values.reduce(into: Set([1, 6])) { $0.formUnion($1) }
    }

    public func setVisibleMeters(_ blocks: Set<Int>, owner: UUID) {
        let before = desiredMeterBlocks
        viewMeters[owner] = blocks.isEmpty ? nil : blocks
        guard state == .online else { return }
        let after = desiredMeterBlocks
        for b in before.subtracting(after) { unsubscribe(meterBlock: b) }
        for b in after.subtracting(before) { subscribe(meterBlock: b) }
    }

    public func subscribe(meterBlock b: Int) {
        guard b >= 0, b < schema.meterIds.count else { return }
        meterSubs[b] = MeterSub(block: b, state: 1, lastSent: now())
        sendBatchSubscribe(b)
    }

    public func unsubscribe(meterBlock b: Int) {
        guard meterSubs.removeValue(forKey: b) != nil else { return }
        send(OSCMessage("/unsubscribe", [.string(schema.meterIds[b])]))
    }

    public var subscribedMeterBlocks: [Int] { meterSubs.keys.sorted() }

    private func sendBatchSubscribe(_ b: Int) {
        guard state.isConnected || syncPhase == .finishing else { return }
        let rate = (b == 4 ? (rtaHalfRate ? 1 : 0) : (meterHalfRate ? 1 : 0)) + 1
        let sel = Int32(selectedChannel)
        send(OSCMessage("/batchsubscribe", [.string(schema.meterIds[b]), .string(schema.meterPaths[b]),
                                            .int(sel), .int(sel), .int(Int32(rate))]))
    }

    private func resubscribeAll() {
        for b in meterSubs.keys { meterSubs[b]?.state = 1; meterSubs[b]?.lastSent = now(); sendBatchSubscribe(b) }
    }

    // MARK: Timers (OscSub::run)

    public func tick(now: ContinuousClock.Instant) {
        // keepalive every 2 s
        if host != nil, lastKeepalive.map({ now - $0 >= timing.keepalive }) ?? true {
            lastKeepalive = now
            if state.isConnected { send(OSCMessage("/xremotenfb")) }
            else if case .reconnecting = state, let h = host { send(OSCMessage("/xinfo"), to: h) }
        }
        // /status handshake retries
        if case .connecting(let ip) = state, let sent = statusSentAt, now - sent >= timing.statusRetry {
            if statusAttempts >= timing.statusMaxAttempts {
                state = .failed("No response from \(ip). Check the IP address and that the mixer is on the same network.")
                resumeOnline(false)
            } else if device != nil {
                sendStatus()
            } else {
                send(OSCMessage("/xinfo"), to: ip); statusSentAt = now; statusAttempts += 1
            }
        }
        // meter renew / resubscribe
        if state.isConnected {
            for (b, var sub) in meterSubs where now - sub.lastSent >= timing.renew {
                sub.lastSent = now
                if sub.state <= timing.renewsBeforeResubscribe {
                    send(OSCMessage("/renew", [.string(schema.meterIds[b])]))
                    sub.state += 1
                } else {
                    sendBatchSubscribe(b)
                    sub.state = 2
                }
                meterSubs[b] = sub
            }
        }
        // node request retries (500 ms, bounded)
        for (path, var p) in pending where now - p.sentAt >= timing.nodeRetry {
            if p.attempts >= timing.nodeMaxAttempts {
                resolve(path, ok: false)
                continue
            }
            p.attempts += 1
            p.sentAt = now
            pending[path] = p
            if let write = p.write { send(write) }
            send(p.message)
        }
        pumpRequests(now: now)
        // read-back after edits
        if state == .online {
            for (node, due) in verifyDue where now >= due {
                verifyDue.removeValue(forKey: node)
                if store.isNode(node) || node.hasSuffix("/par") { requestNode(node) }
            }
        }
        // link loss (OscSub::run: 10 s without data)
        if state.isConnected, let rx = lastRx, now - rx >= timing.linkTimeout {
            lostConnection()
        }
    }

    private func lostConnection() {
        resetLink()
        if autoReconnect, let d = reconnectDevice {
            host = d.ip
            state = .reconnecting(d.ip)
            lastError = "Lost connection. Auto reconnect is active."
        } else {
            state = .failed("Lost connection to the mixer.")
            host = nil
        }
    }

    // MARK: Receiving (OscCom::handleMessage)

    func receive(_ dg: Datagram) {
        stats.packetsIn += 1
        let message: OSCMessage
        do { message = try OSCCodec.decode(dg.data) } catch { stats.decodeErrors += 1; return }
        let fromHost = host != nil && dg.host == host && dg.port == port

        if message.address == "/xinfo" {
            if dg.port == port { handleXinfo(message, from: dg.host) }
            return
        }
        if message.address == "/status" {
            if fromHost { handleStatus(message) }
            return
        }
        guard fromHost else { stats.ignoredForeign += 1; return }
        lastRx = now()

        if let block = MeterDecoder.blockIndex(address: message.address), !message.address.hasPrefix("/") {
            guard case .blob(let blob)? = message.arguments.first,
                  let values = MeterDecoder.decode(blob: blob, expectedCount: schema.meterBatchSize[safe: block]) else { return }
            meters.update(block: block, values: values)
            return
        }
        if message.address == "node" {
            guard message.arguments.count == 1, case .string(let text)? = message.arguments.first else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let l = String(line)
                let changes = store.applyNodeText(l)
                if let p = NodeText.tokenize(l).first { resolve(p.hasPrefix("/") ? p : "/" + p, ok: true) }
                observeDirectoryChanges(changes)
            }
            return
        }
        guard message.address.hasPrefix("/"), state.isConnected || syncPhase != .idle else { return }
        let changes = store.apply(message)
        resolve(message.address, ok: true)
        observeDirectoryChanges(changes)
    }

    private func handleXinfo(_ m: OSCMessage, from source: String) {
        let s = m.arguments.prefix(4).compactMap(\.stringValue)
        guard s.count == 4 else { return }
        // Field order from OscCom::handleMessage: IP, NAME, MODEL, FW.
        let dev = MixerDevice(ip: s[0].isEmpty ? source : s[0], name: s[1], modelString: s[2], firmware: s[3])
        if let i = discovered.firstIndex(where: { $0.ip == dev.ip }) { discovered[i] = dev } else { discovered.append(dev) }
        // Manual-IP connect or auto reconnect: the reply from our host proceeds to /status.
        if case .connecting(let ip) = state, ip == source, device == nil {
            var chosen = dev
            chosen.ip = source
            connect(to: chosen)
        } else if case .reconnecting(let ip) = state, ip == source {
            var chosen = dev
            chosen.ip = source
            connect(to: chosen)
        }
    }

    private func handleStatus(_ m: OSCMessage) {
        // "/status ,sss" — arg1 IP, arg2 name (ConnectPage::checkAndConnectDevice).
        let s = m.arguments.compactMap(\.stringValue)
        guard s.count == 3, case .connecting = state, let dev = device else { return }
        if !s[1].isEmpty && s[1] != dev.ip && s[1] != host { return }
        guard let mdl = dev.model else { return }
        model = mdl
        store.setModel(mdl)
        lastRx = now()
        statusSentAt = nil
        lastError = nil
        beginSync()
    }

    // MARK: Channel / bus link mirroring (Cnode::copyLinkCh semantics)

    /// Partner path for a linked pair, or nil.
    public func linkPartner(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        if parts[0] == "ch", let n = Int(parts[1]), (1...16).contains(n) {
            let a = n % 2 == 1 ? n : n - 1
            guard store.bool("/config/chlink/\(a)-\(a + 1)") else { return nil }
            let partner = n % 2 == 1 ? n + 1 : n - 1
            return "/ch/" + String(format: "%02d", partner) + "/" + parts[2...].joined(separator: "/")
        }
        if parts[0] == "bus", let n = Int(parts[1]), (1...6).contains(n) {
            let a = n % 2 == 1 ? n : n - 1
            guard store.bool("/config/buslink/\(a)-\(a + 1)") else { return nil }
            let partner = n % 2 == 1 ? n + 1 : n - 1
            return "/bus/\(partner)/" + parts[2...].joined(separator: "/")
        }
        return nil
    }

    /// The linkcfg gate by parent node type (Cnode::copyLinkCh): 7 preamp, 12-14 EQ, 8-10 dyn, 16 fader/mute.
    public func linkAllowed(path: String) -> Bool {
        guard let spec = store.spec(path), !spec.linkExcluded else { return false }
        let parentType = schema.nodes[path.oscParent]?.typeCode ?? 0
        switch parentType {
        case 7: return store.bool("/config/linkcfg/preamp")
        case 12, 13, 14: return store.bool("/config/linkcfg/eq")
        case 8, 9, 10: return store.bool("/config/linkcfg/dyn")
        case 16: return store.bool("/config/linkcfg/fdrmute")
        default: return true
        }
    }

    private func mirrorLinked(path: String, index: Int?, string: String?) {
        if path.hasPrefix("/headamp/") { mirrorHeadamp(path, index: index); return }
        guard let partner = linkPartner(of: path), linkAllowed(path: path) else { return }
        if let index, store.store(partner, index: index), state.isConnected, let a = store.oscArgument(partner) {
            send(OSCMessage(partner, [a]))
        }
        if let string, store.store(partner, string: string), state.isConnected { send(OSCMessage(partner, [.string(string)])) }
    }

    private func mirrorHeadamp(_ path: String, index: Int?) {
        guard let index, let model, store.bool("/config/linkcfg/preamp") else { return }
        let parts = path.split(separator: "/")
        guard parts.count == 3, let ha = Int(parts[1]) else { return }
        for ch in 1...model.channelCount {
            let src = store.index(String(format: "/ch/%02d/config/insrc", ch))
            guard model.headampIndex(forInputSource: src) == ha,
                  let partnerCfg = linkPartner(of: String(format: "/ch/%02d/config/insrc", ch)) else { continue }
            let psrc = store.index(partnerCfg)
            guard let pha = model.headampIndex(forInputSource: psrc), pha != ha else { continue }
            let target = String(format: "/headamp/%02d/", pha) + String(parts[2])
            if store.store(target, index: index), state.isConnected, let a = store.oscArgument(target) { send(OSCMessage(target, [a])) }
        }
    }

    /// When a link is switched on, copy the odd channel/bus to its partner (copyLinkCh).
    private func copyLink(pairKey: String) {
        let pair = pairKey.oscLastComponent.split(separator: "-").compactMap { Int($0) }
        guard pair.count == 2 else { return }
        let isBus = pairKey.hasPrefix("/config/buslink/")
        let src = isBus ? "/bus/\(pair[0])" : String(format: "/ch/%02d", pair[0])
        for node in schema.nodeOrder where node.hasPrefix(src + "/") {
            for (leaf, _) in store.nodeMembers(node) where linkAllowed(path: leaf) {
                guard let partner = linkPartner(of: leaf) else { continue }
                let v = store.value(leaf)
                if let v, store.store(partner, index: v.index, string: v.string), state.isConnected, let a = store.oscArgument(partner) {
                    send(OSCMessage(partner, [a]))
                }
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
