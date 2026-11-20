import Foundation

/// Thread-agnostic value table used by the simulator (and file tools).
public struct ValueTable: Sendable {
    public let schema: XAirSchema
    public var index: [String: Int] = [:]
    public var string: [String: String] = [:]

    public init(schema: XAirSchema = .shared) { self.schema = schema }

    public func fxType(_ slot: Int) -> String {
        let i = index["/fx/\(slot)/type"] ?? 0
        return i >= 0 && i < schema.fxTypes.count ? schema.fxTypes[i] : "HALL"
    }

    public func spec(_ path: String) -> ParamSpec? {
        if let slot = XAirSchema.fxSlot(of: path), path.hasPrefix("/fx/\(slot)/par/") {
            let n = Int(path.oscLastComponent) ?? 0
            let specs = schema.fxParams[fxType(slot)] ?? []
            return n >= 1 && n <= specs.count ? specs[n - 1] : nil
        }
        return schema.leaf(path)?.spec
    }

    public func members(_ node: String) -> [(String, ParamSpec)] {
        if let slot = XAirSchema.fxSlot(of: node), node == "/fx/\(slot)/par" {
            return (schema.fxParams[fxType(slot)] ?? []).enumerated().map { (String(format: "/fx/%d/par/%02d", slot, $0.offset + 1), $0.element) }
        }
        guard let n = schema.nodes[node] else { return [] }
        return n.params.map { ((node == "/" ? "" : node) + "/" + $0.name, $0) }
    }

    public func isNode(_ p: String) -> Bool { schema.nodes[p] != nil || (XAirSchema.fxSlot(of: p) != nil && p.hasSuffix("/par")) }

    public func arg(_ leaf: String) -> OSCArgument? {
        guard let s = spec(leaf) else { return nil }
        return s.oscArgument(index: index[leaf] ?? 0, string: string[leaf] ?? "")
    }

    public func message(for path: String) -> OSCMessage? {
        if isNode(path) {
            let m = members(path)
            guard !m.isEmpty else { return nil }
            return OSCMessage(path, m.compactMap { arg($0.0) })
        }
        guard let a = arg(path) else { return nil }
        return OSCMessage(path, [a])
    }

    /// Applies a set; returns the leaf paths that changed.
    @discardableResult
    public mutating func apply(_ m: OSCMessage) -> [String] {
        let targets = isNode(m.address) ? members(m.address) : (spec(m.address).map { [(m.address, $0)] } ?? [])
        var changed: [String] = []
        for (a, (leaf, s)) in zip(m.arguments, targets) {
            switch a {
            case .string(let v) where s.isString:
                if string[leaf] != v { string[leaf] = v; changed.append(leaf) }
            case .int, .float:
                guard !s.isString, let i = s.index(from: a) else { continue }
                if index[leaf] != i { index[leaf] = i; changed.append(leaf) }
            default: continue
            }
        }
        return changed
    }

    @discardableResult
    public mutating func apply(text line: String) -> [String] {
        var t = NodeText.tokenize(line)
        guard !t.isEmpty else { return [] }
        var path = t.removeFirst()
        if !path.hasPrefix("/") { path = "/" + path }
        let targets = isNode(path) ? members(path) : (spec(path).map { [(path, $0)] } ?? [])
        var changed: [String] = []
        for (tok, (leaf, s)) in zip(t, targets) {
            guard let v = ValueText.parse(spec: s, token: tok) else { continue }
            if s.isString { string[leaf] = v.string } else { index[leaf] = v.index }
            changed.append(leaf)
        }
        return changed
    }

    public func text(for node: String) -> String? {
        let m = members(node)
        guard !m.isEmpty else { return nil }
        return String(node.dropFirst()) + " " + m.map { NodeText.encodeToken(spec: $0.1, index: index[$0.0] ?? 0, string: string[$0.0] ?? "") }.joined(separator: " ")
    }

    public mutating func resetFX(slot: Int) {
        for (i, s) in (schema.fxParams[fxType(slot)] ?? []).enumerated() {
            index[String(format: "/fx/%d/par/%02d", slot, i + 1)] = s.defaultIndex ?? 0
        }
    }

    public static func defaultState(schema: XAirSchema = .shared) -> ValueTable {
        var t = ValueTable(schema: schema)
        if let url = Bundle.module.url(forResource: "default-state", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) { t.apply(text: String(line)) }
        }
        return t
    }
}

/// In-process datagram link between a client and the simulator.
public final class LoopbackLink: @unchecked Sendable {
    public let clientHost: String
    public let mixerHost: String
    public let mixerPort: UInt16
    fileprivate let queue = DispatchQueue(label: "xair.loopback")
    fileprivate var clientRx: (@Sendable (Datagram) -> Void)?
    fileprivate var mixerRx: (@Sendable (Datagram) -> Void)?
    /// Drop every Nth client->mixer packet (0 = never) to exercise retries.
    public var dropEvery = 0
    private var counter = 0
    public var mixerReachable = true

    public init(clientHost: String = "127.0.0.2", mixerHost: String = "127.0.0.1", mixerPort: UInt16 = 10024) {
        self.clientHost = clientHost
        self.mixerPort = mixerPort
        self.mixerHost = mixerHost
    }

    public lazy var clientEndpoint: DatagramTransport = Endpoint(link: self, isClient: true)
    public lazy var mixerEndpoint: DatagramTransport = Endpoint(link: self, isClient: false)

    fileprivate func deliver(_ data: Data, fromClient: Bool, port: UInt16) {
        queue.async {
            if fromClient {
                self.counter += 1
                if self.dropEvery > 0 && self.counter % self.dropEvery == 0 { return }
                guard self.mixerReachable else { return }
                self.mixerRx?(Datagram(data: data, host: self.clientHost, port: 50000))
            } else {
                guard self.mixerReachable else { return }
                self.clientRx?(Datagram(data: data, host: self.mixerHost, port: self.mixerPort))
            }
        }
    }

    final class Endpoint: DatagramTransport, @unchecked Sendable {
        let link: LoopbackLink
        let isClient: Bool
        init(link: LoopbackLink, isClient: Bool) { self.link = link; self.isClient = isClient }
        func start(onReceive: @escaping @Sendable (Datagram) -> Void) throws {
            link.queue.sync { if isClient { link.clientRx = onReceive } else { link.mixerRx = onReceive } }
        }
        func send(_ data: Data, to host: String, port: UInt16) throws {
            link.deliver(data, fromClient: isClient, port: port)
        }
        func stop() { link.queue.sync { if isClient { link.clientRx = nil } else { link.mixerRx = nil } } }
    }
}

/// Deterministic X-Air mixer emulator implementing the server side of PROTOCOL.md.
public final class MixerSimulator: @unchecked Sendable {
    public struct Identity: Sendable {
        public var ip: String
        public var name: String
        public var model: String
        public var firmware: String
        public init(ip: String = "127.0.0.1", name: String = "XR18-Simulator", model: String = "XR18", firmware: String = "1.22") {
            self.ip = ip; self.name = name; self.model = model; self.firmware = firmware
        }
    }

    private struct Client: Hashable { let host: String; let port: UInt16 }
    private struct Remote { var expires: UInt64; var noFeedback: Bool }
    private struct MeterSub { var id: String; var block: Int; var rate: Int; var selection: Int; var expires: UInt64; var client: Client; var lastTick: UInt64 }

    public var identity: Identity
    private let transport: DatagramTransport
    private let queue = DispatchQueue(label: "xair.simulator")
    private var table: ValueTable
    private let defaults: ValueTable
    private var remotes: [Client: Remote] = [:]
    private var meterSubs: [String: MeterSub] = [:]
    private var snapshots: [Int: ValueTable] = [:]
    private var timer: DispatchSourceTimer?
    /// Simulated time in 50 ms ticks; advances in `tick()`.
    public private(set) var ticks: UInt64 = 0
    /// Received message log (address only) for tests.
    private var log: [String] = []
    public var answersNodeQueries = true

    public init(transport: DatagramTransport, identity: Identity = Identity()) {
        self.transport = transport
        self.identity = identity
        var t = ValueTable.defaultState()
        MixerModel(modelString: identity.model)?.applyFactoryDifferences { t.index[$0] = $1 }
        // Values the scene file does not contain.
        t.string["/-prefs/name"] = identity.name
        t.index["/-prefs/lan/mode"] = 1
        for (i, v) in [192, 168, 1, 1].enumerated() { t.index["/-prefs/lan/addr/\(i)"] = v }
        for (i, v) in [255, 255, 255, 0].enumerated() { t.index["/-prefs/lan/mask/\(i)"] = v }
        t.string["/-prefs/ap/ssid"] = identity.name
        t.index["/-prefs/ap/channel"] = 6
        t.index["/-snap/index"] = 1
        t.index["/-stat/netmode"] = 2
        let isRecorderModel = MixerModel(modelString: identity.model)?.hasUSBRecorder == true
        t.index["/-stat/usbmounted"] = isRecorderModel ? 1 : 0
        if isRecorderModel {
            Self.populateDirectory("/", in: &t)
        }
        for slot in 1...4 where t.index[String(format: "/fx/%d/par/01", slot)] == nil { t.resetFX(slot: slot) }
        table = t
        defaults = t
    }

    private static let directories: [String: [(Int, String)]] = [
        "/": [(1, "SONGS"), (0, "R_20261107-120000.wav"), (0, "Intro.wav")],
        "/SONGS": [(0, "Soundcheck.wav"), (1, "Archive"), (0, "Encore.wav")],
        "/SONGS/Archive": []
    ]

    private static func populateDirectory(_ path: String, in table: inout ValueTable) {
        let key = "/" + path.split(separator: "/").joined(separator: "/")
        guard let entries = directories[key] else { return }
        let previous = table.index["/-stat/usb/count"] ?? 0
        table.string["/-stat/usb/path"] = key
        table.index["/-stat/usb/count"] = entries.count
        for i in 0..<max(previous, entries.count) {
            let node = table.schema.usbDirPaths[i]
            let entry = entries.indices.contains(i) ? entries[i] : (0, "")
            table.index[node + "/type"] = entry.0
            table.string[node + "/name"] = entry.1
        }
    }

    public func start(autoTick: Bool = true) throws {
        try transport.start { [weak self] dg in self?.queue.async { self?.handle(dg) } }
        if autoTick {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.tickLocked() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        timer?.cancel(); timer = nil
        transport.stop()
    }

    /// Advance simulated time by one 50 ms tick (manual mode).
    public func tick() { queue.sync { tickLocked() } }

    public func value(_ path: String) -> Int? { queue.sync { table.index[path] } }
    public func stringValue(_ path: String) -> String? { queue.sync { table.string[path] } }
    public var receivedAddresses: [String] { queue.sync { log } }
    public var meterSubscriptionIDs: [String] { queue.sync { meterSubs.keys.sorted() } }
    public var remoteClientCount: Int { queue.sync { remotes.count } }

    /// Change a value "on the mixer surface" (another client), notifying remotes.
    public func externalSet(_ path: String, index: Int) {
        queue.sync {
            guard let s = table.spec(path) else { return }
            table.index[path] = s.clamp(index)
            if let m = table.message(for: path) { broadcast(m, except: nil) }
        }
    }

    public func externalSet(_ path: String, string: String) {
        queue.sync {
            table.string[path] = string
            if let m = table.message(for: path) { broadcast(m, except: nil) }
        }
    }

    // MARK: Protocol

    private func handle(_ dg: Datagram) {
        let client = Client(host: dg.host, port: dg.port)
        // The original's discovery probe is 6 raw bytes (not OSC-aligned).
        if dg.data == Data("/xinfo".utf8) { reply(xinfo(), to: client); log.append("/xinfo(raw)"); return }
        guard let m = try? OSCCodec.decode(dg.data) else { return }
        log.append(m.address)
        switch m.address {
        case "/xinfo": reply(xinfo(), to: client)
        case "/status": reply(OSCMessage("/status", [.string("active"), .string(identity.ip), .string(identity.name)]), to: client)
        case "/xremote", "/xremotenfb":
            remotes[client] = Remote(expires: ticks + 200, noFeedback: m.address == "/xremotenfb")
        case "/batchsubscribe":
            let s = m.arguments
            guard s.count == 5, case .string(let id) = s[0], case .string(let path) = s[1],
                  let block = MeterDecoder.blockIndex(address: String(path.dropFirst())) else { return }
            let rate = max(1, s[4].intValue ?? 1)
            meterSubs[id] = MeterSub(id: id, block: block, rate: rate, selection: s[2].intValue ?? 0, expires: ticks + 200, client: client, lastTick: ticks)
        case "/renew":
            if case .string(let id)? = m.arguments.first { meterSubs[id]?.expires = ticks + 200 }
        case "/unsubscribe":
            if case .string(let id)? = m.arguments.first { meterSubs.removeValue(forKey: id) } else { meterSubs.removeAll() }
        default:
            if m.arguments.isEmpty {
                guard answersNodeQueries, let r = table.message(for: m.address) else { return }
                reply(r, to: client)
            } else {
                handleSet(m, from: client)
            }
        }
    }

    private func handleSet(_ m: OSCMessage, from client: Client) {
        switch m.address {
        case "/-stat/usb/path":
            guard table.index["/-stat/usbmounted"] == 1, case .string(let path)? = m.arguments.first else { return }
            Self.populateDirectory(path, in: &table)
            if let header = table.message(for: "/-stat/usb") { broadcast(header, except: client) }
            return
        case "/-snap/save":
            guard let n = m.arguments.first?.intValue, (1...64).contains(n) else { return }
            snapshots[n] = table
            let scopePath = String(format: "/-snap/%02d/scope", n)
            if table.string[scopePath, default: ""].isEmpty { table.string[scopePath] = SnapshotScope(all: true).string }
            table.string[String(format: "/-snap/%02d/name", n)] = table.string["/-snap/name"] ?? "Snapshot \(n)"
            table.index["/-snap/index"] = n
            broadcastLeaves([String(format: "/-snap/%02d/name", n), scopePath, "/-snap/index"], except: nil)
            return
        case "/-snap/load":
            guard let n = m.arguments.first?.intValue, let saved = snapshots[n],
                  let model = MixerModel(modelString: identity.model) else { return }
            let scope = SnapshotScope(string: table.string[String(format: "/-snap/%02d/scope", n)] ?? "")
            guard scope.isValid else { return }
            var changed: [String] = []
            for node in table.schema.syncPaths {
                for (leaf, _) in saved.members(node) where scope.includes(leaf, saved: saved, model: model) {
                    if let value = saved.arg(leaf) { changed += table.apply(OSCMessage(leaf, [value])) }
                }
            }
            table.string["/-snap/name"] = table.string[String(format: "/-snap/%02d/name", n)]
            table.index["/-snap/index"] = n
            broadcastLeaves(changed + ["/-snap/index", "/-snap/name"], except: nil)
            return
        case "/-snap/delete":
            guard let n = m.arguments.first?.intValue, (1...64).contains(n) else { return }
            snapshots.removeValue(forKey: n)
            table.string[String(format: "/-snap/%02d/scope", n)] = ""
            table.string[String(format: "/-snap/%02d/name", n)] = ""
            broadcastLeaves([String(format: "/-snap/%02d/name", n), String(format: "/-snap/%02d/scope", n)], except: nil)
            return
        case "/-action/initall":
            guard m.arguments.first?.intValue == 1 else { return }
            table = defaults
            for p in table.schema.syncPaths { if let msg = table.message(for: p) { broadcast(msg, except: nil) } }
            return
        case "/-action/clearsolo":
            var changed: [String] = []
            for i in 1...54 { let p = String(format: "/-stat/solosw/%02d", i); if table.index[p] != 0 { table.index[p] = 0; changed.append(p) } }
            table.index["/-stat/solo"] = 0
            broadcastLeaves(changed + ["/-stat/solo"], except: nil)
            return
        case "/-action/wlanscan":
            for (i, (ssid, strength)) in [("Studio-5G", 82), ("Venue-Guest", 54)].enumerated() {
                let p = String(format: "/-stat/networks/%02d", i + 1)
                table.string[p + "/ssid"] = ssid; table.index[p + "/strength"] = strength; table.index[p + "/flags"] = 3
            }
            broadcastLeaves(["/-stat/networks/01/ssid", "/-stat/networks/02/ssid"], except: nil)
            return
        default:
            break
        }
        let changed = table.apply(m)
        let fxType = m.address.split(separator: "/")
        if fxType.count == 3, fxType[0] == "fx", fxType[2] == "type", let slot = Int(fxType[1]), !changed.isEmpty {
            table.resetFX(slot: slot)
            if let par = table.message(for: "/fx/\(slot)/par") { broadcast(par, except: nil) }
        }
        if m.address == "/-stat/tape/state" { table.index["/-stat/tape/etime"] = table.index["/-stat/tape/etime"] ?? 0 }
        if !changed.isEmpty { broadcast(m, except: client) }
    }

    private func xinfo() -> OSCMessage {
        OSCMessage("/xinfo", [.string(identity.ip), .string(identity.name), .string(identity.model), .string(identity.firmware)])
    }

    private func reply(_ m: OSCMessage, to c: Client) {
        try? transport.send(OSCCodec.encode(m), to: c.host, port: c.port)
    }

    private func broadcast(_ m: OSCMessage, except sender: Client?) {
        for (c, r) in remotes {
            if let sender, c == sender, r.noFeedback { continue }
            reply(m, to: c)
        }
    }

    private func broadcastLeaves(_ leaves: [String], except: Client?) {
        for l in Set(leaves) { if let m = table.message(for: l) { broadcast(m, except: except) } }
    }

    // MARK: Time / meters

    private func tickLocked() {
        ticks &+= 1
        remotes = remotes.filter { $0.value.expires > ticks }
        meterSubs = meterSubs.filter { $0.value.expires > ticks }
        if table.index["/-stat/tape/state"] == 2 || table.index["/-stat/tape/state"] == 4, ticks % 20 == 0 {
            table.index["/-stat/tape/etime", default: 0] += 1
            broadcastLeaves(["/-stat/tape/etime"], except: nil)
        }
        for (id, var sub) in meterSubs where ticks - sub.lastTick >= UInt64(sub.rate) {
            sub.lastTick = ticks
            meterSubs[id] = sub
            let values = meterValues(block: sub.block, selection: sub.selection)
            reply(OSCMessage(id, [.blob(MeterDecoder.encode(values: values))]), to: sub.client)
        }
    }

    /// Deterministic synthetic levels: a slow sine per channel, scaled by fader and mute.
    func meterValues(block: Int, selection: Int = 0) -> [Int16] {
        let count = table.schema.meterBatchSize[safe: block] ?? 0
        return (0..<count).map { i -> Int16 in
            let phase = Double(ticks) * 0.12 + Double(i) * 0.7
            var dB = -30 + 18 * sin(phase)
            if block == 0 { dB += 3 * sin(Double(selection + i)) }
            if block == 3, (2...11).contains(i % 14) {
                let unit = (sin(phase) + 1) / 2
                let effect = table.fxType(i / 14 + 1)
                let scale: Double = effect == "LIM" ? 210 : 2048
                return Int16(unit * scale)
            }
            if block == 6 || block == 7 || block == 0 && (2...3).contains(i) { dB = -6 + 6 * sin(phase) }
            if block == 1 || block == 2 {
                let ch = i < 16 ? String(format: "/ch/%02d/mix", i + 1) : nil
                if let ch, block == 1, (table.index[ch + "/on"] ?? 1) == 0 { dB = -90 }
            }
            if block == 4 { dB = -60 + 30 * exp(-pow(Double(i) - 30 - 10 * sin(Double(ticks) * 0.05), 2) / 200) }
            if block == 7 { dB = -20 + 4 * sin(phase) }
            return Int16(clamping: Int(max(-128, min(127, dB)) * 256))
        }
    }
}
