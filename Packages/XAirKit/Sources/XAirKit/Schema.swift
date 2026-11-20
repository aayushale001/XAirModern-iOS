import Foundation

/// Parameter kinds, one per original `Cparam` type code (PROTOCOL.md §4).
public enum ParamKind: Sendable, Equatable {
    case string(maxLength: Int)                                   // 0xc5
    case int(min: Int, max: Int, format: String)                  // 0xc1
    case enumeration([String])                                    // 0xc2
    case linear(steps: Int, min: Float, max: Float, format: String) // 0xc3
    case log(steps: Int, min: Float, k: Float, format: String)    // 0xc4  value = min*exp(k*i)
    case fader(steps: Int)                                        // 0xc6  '#f'
    case sendLevel(steps: Int)                                    // 0xc7  '#l'
}

/// A parameter definition. Values are held as the original app holds them:
/// an integer step index (Cparam+0x5c) for every numeric type, or a string.
public struct ParamSpec: Sendable, Equatable {
    public let name: String
    public let kind: ParamKind
    /// Cparam+0x69: excluded from channel-link copy (Cnode::copyLinkCh).
    public let linkExcluded: Bool
    /// FX parameters only: label and default index from Cfxdsp::fxparcfg_*.
    public let label: String?
    public let defaultIndex: Int?

    public init(name: String, kind: ParamKind, linkExcluded: Bool = false, label: String? = nil, defaultIndex: Int? = nil) {
        self.name = name
        self.kind = kind
        self.linkExcluded = linkExcluded
        self.label = label
        self.defaultIndex = defaultIndex
    }

    public var isString: Bool { if case .string = kind { return true }; return false }

    /// Cparam+0x4c (lower index bound).
    public var minIndex: Int {
        if case .int(let mn, _, _) = kind { return mn }
        return 0
    }

    /// Cparam+0x50 (upper index bound / step count).
    public var maxIndex: Int {
        switch kind {
        case .string(let n): n
        case .int(_, let mx, _): mx
        case .enumeration(let items): max(items.count - 1, 0)
        case .linear(let s, _, _, _), .log(let s, _, _, _), .fader(let s), .sendLevel(let s): s
        }
    }

    public var isFloatOnWire: Bool {
        switch kind {
        case .linear, .log, .fader, .sendLevel: true
        default: false
        }
    }

    public func clamp(_ index: Int) -> Int { Swift.min(Swift.max(index, minIndex), maxIndex) }

    // MARK: Cparam::getFloat

    public func value(forIndex i: Int) -> Float {
        switch kind {
        case .string: return 0
        case .int, .enumeration: return Float(i)
        case .linear(let steps, let mn, let mx, _):
            return mn + (mx - mn) * Float(i) / Float(steps)
        case .log(_, let mn, let k, _):
            return mn * Float(exp(Double(k) * Double(i)))
        case .fader(let n), .sendLevel(let n):
            return ParamSpec.levelDB(index: i, steps: n)
        }
    }

    /// The 4-segment fader law of Cparam::getFloat (types 0xc6/0xc7).
    public static func levelDB(index i: Int, steps n: Int) -> Float {
        let half = (n + 1) >> 1, quarter = (n + 1) >> 2, sixteenth = (n + 1) >> 4
        let fi = Float(i), fn = Float(n)
        if i >= half { return fi * 40 / fn - 30 }
        if i >= quarter { return fi * 80 / fn - 50 }
        if i >= sixteenth { return fi * 160 / fn - 70 }
        if i == 0 { return -144 }
        return fi * 480 / fn - 90
    }

    // MARK: Cparam::setFloat

    public func index(forValue v: Float) -> Int {
        guard v.isFinite else { return minIndex }
        switch kind {
        case .string: return 0
        case .int, .enumeration:
            if v <= Float(minIndex) { return minIndex }
            if v >= Float(maxIndex) { return maxIndex }
            return clamp(Int(v.rounded()))
        case .linear(let steps, let mn, let mx, _):
            guard mx != mn else { return 0 }
            let bounded = min(max(v, min(mn, mx)), max(mn, mx))
            return clamp(Int((bounded - mn) * Float(steps) / (mx - mn) + 0.5))
        case .log(_, let mn, let k, _):
            guard mn > 0, k != 0, v > 0 else { return minIndex }
            let x = log(Double(v) / Double(mn)) / Double(k)
            return Int(min(max(x + 0.5, 0), Double(maxIndex)))
        case .fader(let n), .sendLevel(let n):
            if v >= 10 { return n }
            let fn = Float(n)
            let x: Float
            if v >= -10 { x = (v + 30) * fn / 40 }
            else if v >= -30 { x = (v + 50) * fn / 80 }
            else if v >= -60 { x = (v + 70) * fn / 160 }
            else if v <= -90 { return clamp(0) }
            else { x = (v + 90) * fn / 480 }
            return clamp(Int(x + 0.5))
        }
    }

    // MARK: Wire conversion (Cparam::getOscMessage / CmessageQueue 'O' decode)

    public func oscArgument(index: Int, string: String) -> OSCArgument {
        switch kind {
        case .string: return .string(string)
        case .int, .enumeration: return .int(Int32(index))
        default: return .float(Float(index) / Float(maxIndex))
        }
    }

    /// Converts an inbound OSC argument to an index, exactly as the original:
    /// `f` -> (int)((imax + 0.5) * f) clamped; `i` -> clamped.
    public func index(from argument: OSCArgument) -> Int? {
        switch argument {
        case .float(let f):
            guard f.isFinite else { return nil }
            let raw = (Double(maxIndex) + 0.5) * Double(f)
            return Int(min(max(raw, Double(minIndex)), Double(maxIndex)))
        case .int(let i):
            return clamp(Int(i))
        default:
            return nil
        }
    }

    /// Display unit inferred from the parameter name (presentation only).
    public var enumItems: [String] {
        if case .enumeration(let items) = kind { return items }
        return []
    }
}

public struct NodeSpec: Sendable, Equatable {
    public let path: String
    public let typeCode: Int
    public let params: [ParamSpec]
    public let children: [String]

    public func param(named n: String) -> (offset: Int, spec: ParamSpec)? {
        guard let i = params.firstIndex(where: { $0.name == n }) else { return nil }
        return (i, params[i])
    }
}

/// The complete parameter schema extracted from X-AIR-Edit 1.8.1 (see tools/gen_schema.py).
public final class XAirSchema: Sendable {
    public static let shared: XAirSchema = {
        guard let url = Bundle.module.url(forResource: "xair-schema", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let schema = try? XAirSchema(json: data) else {
            fatalError("xair-schema.json missing from XAirKit bundle")
        }
        return schema
    }()

    public let nodes: [String: NodeSpec]
    public let nodeOrder: [String]
    public let fxTypes: [String]
    public let fxLongNames: [String]
    public let fxParams: [String: [ParamSpec]]
    public let syncPaths: [String]
    public let prefStatSnapPaths: [String]
    public let usbDirPaths: [String]
    public let meterIds: [String]
    public let meterPaths: [String]
    public let meterBatchSize: [Int]
    public let labels: [String: [String]]
    /// Leaf path -> (node path, offset in node arg list)
    private let leafIndex: [String: LeafRef]

    struct LeafRef: Sendable { let node: String; let offset: Int }

    public init(json: Data) throws {
        let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        let enums = (root["enums"] as? [[String]]) ?? []
        func decodeParam(_ raw: [Any]) -> ParamSpec? {
            guard raw.count >= 2, let name = raw[0] as? String, let t = raw[1] as? String else { return nil }
            var extras: [String: Any] = [:]
            if let last = raw.last as? [String: Any] { extras = last }
            if raw.count >= 2, let prev = raw.dropLast().last as? [String: Any] { extras.merge(prev) { a, _ in a } }
            func num(_ i: Int) -> Double { (raw.count > i ? (raw[i] as? NSNumber)?.doubleValue : nil) ?? 0 }
            func str(_ i: Int) -> String { (raw.count > i ? raw[i] as? String : nil) ?? "%f" }
            let kind: ParamKind
            switch t {
            case "s": kind = .string(maxLength: Int(num(2)))
            case "i": kind = .int(min: Int(num(2)), max: Int(num(3)), format: str(4))
            case "e":
                let idx = Int(num(2))
                kind = .enumeration(idx < enums.count ? enums[idx] : [])
            case "l": kind = .linear(steps: Int(num(2)), min: Float(num(3)), max: Float(num(4)), format: str(5))
            case "g": kind = .log(steps: Int(num(2)), min: Float(num(3)), k: Float(num(4)), format: str(5))
            case "f": kind = .fader(steps: Int(num(2)))
            case "v": kind = .sendLevel(steps: Int(num(2)))
            default: return nil
            }
            return ParamSpec(name: name, kind: kind,
                             linkExcluded: (extras["x"] as? Int) == 1,
                             label: extras["label"] as? String,
                             defaultIndex: extras["def"] as? Int)
        }
        var nodes: [String: NodeSpec] = [:]
        var order: [String] = []
        var leaves: [String: LeafRef] = [:]
        for n in (root["nodes"] as? [[String: Any]]) ?? [] {
            guard let p = n["p"] as? String else { continue }
            let params = ((n["c"] as? [[Any]]) ?? []).compactMap(decodeParam)
            let spec = NodeSpec(path: p, typeCode: n["t"] as? Int ?? 0, params: params, children: n["n"] as? [String] ?? [])
            nodes[p] = spec
            order.append(p)
            for (i, prm) in params.enumerated() {
                leaves[(p == "/" ? "" : p) + "/" + prm.name] = LeafRef(node: p, offset: i)
            }
        }
        var fx: [String: [ParamSpec]] = [:]
        for (k, v) in (root["fx"] as? [String: [[Any]]]) ?? [:] { fx[k] = v.compactMap(decodeParam) }
        self.nodes = nodes
        self.nodeOrder = order
        self.leafIndex = leaves
        self.fxTypes = root["fxTypes"] as? [String] ?? []
        let algorithmNames = root["fxLongNames"] as? [String] ?? []
        let algorithms = root["fxAlgorithm"] as? [Int] ?? []
        self.fxLongNames = algorithms.map { algorithmNames[$0] }
        self.fxParams = fx
        self.syncPaths = root["syncPaths"] as? [String] ?? []
        self.prefStatSnapPaths = root["prefStatSnapPaths"] as? [String] ?? []
        self.usbDirPaths = root["usbDirPaths"] as? [String] ?? []
        self.meterIds = root["meterIds"] as? [String] ?? []
        self.meterPaths = root["meterPaths"] as? [String] ?? []
        self.meterBatchSize = root["meterBatchSize"] as? [Int] ?? []
        self.labels = root["labels"] as? [String: [String]] ?? [:]
    }

    /// Resolves a leaf path such as `/ch/01/mix/fader`.
    public func leaf(_ path: String) -> (node: NodeSpec, offset: Int, spec: ParamSpec)? {
        guard let ref = leafIndex[path], let node = nodes[ref.node] else { return nil }
        return (node, ref.offset, node.params[ref.offset])
    }

    public static func fxSlot(of path: String) -> Int? {
        // "/fx/N/par[/MM]"
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "fx", parts[2] == "par", let n = Int(parts[1]) else { return nil }
        return n
    }
}

public extension String {
    /// Parent path of an OSC path (`/a/b/c` -> `/a/b`).
    var oscParent: String {
        guard let r = range(of: "/", options: .backwards), r.lowerBound != startIndex else { return "/" }
        return String(self[..<r.lowerBound])
    }

    var oscLastComponent: String {
        guard let r = range(of: "/", options: .backwards) else { return self }
        return String(self[r.upperBound...])
    }
}
