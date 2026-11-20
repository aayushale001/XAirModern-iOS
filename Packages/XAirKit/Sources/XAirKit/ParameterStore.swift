import Foundation
import Observation

/// One mixer parameter value. Observed per instance so a view only redraws
/// when the parameters it reads change.
@MainActor
@Observable
public final class ParamValue {
    public let path: String
    public internal(set) var index: Int
    public internal(set) var string: String
    /// True once the mixer (or a loaded file) has supplied a value (Cparam+0x68).
    public internal(set) var received: Bool = false
    /// Increments on every change; useful for animations and tests.
    public internal(set) var revision: Int = 0

    init(path: String, index: Int = 0, string: String = "") {
        self.path = path
        self.index = index
        self.string = string
    }
}

public struct ParamChange: Sendable, Equatable {
    public let path: String
    public let index: Int
    public let string: String
}

/// Typed mixer state built from the extracted schema. The mixer is the source of
/// truth: values change only from inbound messages, loaded files, or user edits
/// that are sent to the mixer in the same call (see MixerSession.set).
@MainActor
public final class ParameterStore {
    public let schema: XAirSchema
    private var values: [String: ParamValue] = [:]
    public private(set) var model: MixerModel = .xr18

    public init(schema: XAirSchema = .shared) {
        self.schema = schema
        for path in schema.nodeOrder {
            guard let node = schema.nodes[path] else { continue }
            if XAirSchema.fxSlot(of: path) != nil { continue }
            for p in node.params {
                let leaf = Self.join(path, p.name)
                values[leaf] = ParamValue(path: leaf)
            }
        }
        for slot in 1...4 {
            for i in 1...64 {
                let leaf = String(format: "/fx/%d/par/%02d", slot, i)
                values[leaf] = ParamValue(path: leaf)
            }
        }
    }

    public func setModel(_ m: MixerModel) { model = m }

    static func join(_ node: String, _ name: String) -> String { node == "/" ? "/" + name : node + "/" + name }

    // MARK: Lookup

    public func value(_ path: String) -> ParamValue? { values[path] }

    public var allLeafPaths: [String] { Array(values.keys) }

    /// Spec for a leaf path, resolving FX parameter slots by the slot's current type.
    public func spec(_ path: String) -> ParamSpec? {
        if let slot = XAirSchema.fxSlot(of: path), path.hasPrefix("/fx/\(slot)/par/") {
            let n = Int(path.oscLastComponent) ?? 0
            let specs = fxParamSpecs(slot: slot)
            return n >= 1 && n <= specs.count ? specs[n - 1] : nil
        }
        return schema.leaf(path)?.spec
    }

    public func fxTypeName(slot: Int) -> String {
        let idx = values["/fx/\(slot)/type"]?.index ?? 0
        return idx >= 0 && idx < schema.fxTypes.count ? schema.fxTypes[idx] : "HALL"
    }

    public func fxParamSpecs(slot: Int) -> [ParamSpec] {
        schema.fxParams[fxTypeName(slot: slot)] ?? []
    }

    /// Ordered (leaf path, spec) pairs that make up a node's argument list.
    public func nodeMembers(_ nodePath: String) -> [(String, ParamSpec)] {
        if let slot = XAirSchema.fxSlot(of: nodePath), nodePath == "/fx/\(slot)/par" {
            return fxParamSpecs(slot: slot).enumerated().map { (String(format: "/fx/%d/par/%02d", slot, $0.offset + 1), $0.element) }
        }
        guard let node = schema.nodes[nodePath] else { return [] }
        return node.params.map { (Self.join(nodePath, $0.name), $0) }
    }

    public func isNode(_ path: String) -> Bool { schema.nodes[path] != nil }

    // MARK: Mutation

    /// Sets a value locally. Returns true if it changed.
    @discardableResult
    public func store(_ path: String, index: Int? = nil, string: String? = nil, markReceived: Bool = true) -> Bool {
        guard let v = values[path] else { return false }
        var changed = false
        if let index, let spec = spec(path) {
            let c = spec.clamp(index)
            if v.index != c { v.index = c; changed = true }
        }
        if let string, v.string != string { v.string = string; changed = true }
        if markReceived && !v.received { v.received = true; changed = true }
        if changed { v.revision &+= 1 }
        return changed
    }

    /// Applies an inbound OSC message (node multi-arg or leaf) exactly like the
    /// original decoder: args fill the node's params in order; `f` and `i` are
    /// quantized per spec; `s` is applied only to string params.
    @discardableResult
    public func apply(_ message: OSCMessage) -> [ParamChange] {
        var path = message.address
        if !path.hasPrefix("/") { path = "/" + path }
        let targets: [(String, ParamSpec)]
        if isNode(path) || (XAirSchema.fxSlot(of: path) != nil && path.hasSuffix("/par")) {
            targets = nodeMembers(path)
        } else if let spec = spec(path) {
            targets = [(path, spec)]
        } else {
            return []
        }
        var changes: [ParamChange] = []
        for (arg, (leaf, spec)) in zip(message.arguments, targets) {
            var did = false
            switch arg {
            case .string(let s):
                guard spec.isString else { continue }
                if case .string(let maxLen) = spec.kind {
                    did = store(leaf, string: String(s.prefix(maxLen)))
                }
            case .int, .float:
                guard !spec.isString, let idx = spec.index(from: arg) else { continue }
                did = store(leaf, index: idx)
            case .blob:
                continue
            }
            if did, let v = values[leaf] { changes.append(ParamChange(path: leaf, index: v.index, string: v.string)) }
        }
        return changes
    }

    /// Applies one node text line (`path tok tok ...`). Returns changed values.
    @discardableResult
    public func applyNodeText(_ line: String) -> [ParamChange] {
        var tokens = NodeText.tokenize(line)
        guard !tokens.isEmpty else { return [] }
        var path = tokens.removeFirst()
        if !path.hasPrefix("/") { path = "/" + path }
        let targets: [(String, ParamSpec)]
        if isNode(path) || path.hasSuffix("/par") { targets = nodeMembers(path) }
        else if let s = spec(path) { targets = [(path, s)] }
        else { return [] }
        var changes: [ParamChange] = []
        for (tok, (leaf, spec)) in zip(tokens, targets) {
            guard let parsed = ValueText.parse(spec: spec, token: tok) else { continue }
            let did = spec.isString ? store(leaf, string: parsed.string) : store(leaf, index: parsed.index)
            if did, let v = values[leaf] { changes.append(ParamChange(path: leaf, index: v.index, string: v.string)) }
        }
        return changes
    }

    // MARK: Encoding

    public func oscArgument(_ path: String) -> OSCArgument? {
        guard let v = values[path], let spec = spec(path) else { return nil }
        return spec.oscArgument(index: v.index, string: v.string)
    }

    /// Multi-argument message for a node (PC->mixer sync, OscCom::run branch 1).
    public func nodeMessage(_ nodePath: String) -> OSCMessage? {
        let members = nodeMembers(nodePath)
        guard !members.isEmpty else { return nil }
        return OSCMessage(nodePath, members.compactMap { oscArgument($0.0) })
    }

    /// Node text line as the original writes it (path without leading slash).
    public func nodeText(_ nodePath: String, padFX: Bool = true) -> String? {
        let members = nodeMembers(nodePath)
        guard !members.isEmpty else { return nil }
        var tokens = members.map { leaf, spec in
            NodeText.encodeToken(spec: spec, index: values[leaf]?.index ?? 0, string: values[leaf]?.string ?? "")
        }
        if padFX, XAirSchema.fxSlot(of: nodePath) != nil, nodePath.hasSuffix("/par") {
            while tokens.count < 64 { tokens.append("0") }
        }
        return String(nodePath.dropFirst()) + " " + tokens.joined(separator: " ")
    }

    public func display(_ path: String) -> String {
        guard let v = values[path], let spec = spec(path) else { return "" }
        return ValueText.display(spec: spec, index: v.index, string: v.string)
    }

    public func physical(_ path: String) -> Float {
        guard let v = values[path], let spec = spec(path) else { return 0 }
        return spec.value(forIndex: v.index)
    }

    public func index(_ path: String) -> Int { values[path]?.index ?? 0 }
    public func string(_ path: String) -> String { values[path]?.string ?? "" }
    public func bool(_ path: String) -> Bool { (values[path]?.index ?? 0) != 0 }

    /// Loads the original app's default scene (offline editing starts from it).
    public func loadDefaults() {
        guard let url = Bundle.module.url(forResource: "default-state", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) { applyNodeText(String(line)) }
        model.applyFactoryDifferences { self.store($0, index: $1) }
        for slot in 1...4 {
            for (i, s) in fxParamSpecs(slot: slot).enumerated() where !(values[String(format: "/fx/%d/par/%02d", slot, i + 1)]?.received ?? false) {
                store(String(format: "/fx/%d/par/%02d", slot, i + 1), index: s.defaultIndex ?? 0)
            }
        }
    }

    /// Resets every value to "not received" (used before a fresh sync).
    public func invalidateAll() {
        for v in values.values where v.received { v.received = false; v.revision &+= 1 }
    }
}
