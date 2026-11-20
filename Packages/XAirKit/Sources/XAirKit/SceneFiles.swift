import Foundation

/// Scene, channel-preset, FX-preset and routing files in the original's text
/// format (one `path tok tok ...` line per node, see Cpreset::savePreset and
/// the app's own default state file). Extensions: .scn, .chn, .efx.
public enum PresetScope: String, CaseIterable, Sendable, Identifiable {
    // Cpreset::savePreset cases 1..7 ("Save complete channel preset...", ...)
    case complete, input, gate, compressor, eq, sends, output
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .complete: "Complete channel"
        case .input: "Input / source"
        case .gate: "Gate"
        case .compressor: "Compressor"
        case .eq: "EQ"
        case .sends: "Sends"
        case .output: "Output"
        }
    }

    /// Paths are relative to the selected strip, as in Cpreset::savePreset.
    public var nodeSuffixes: [String] {
        let gate = ["gate", "gate/filter"]
        let dynamics = ["dyn", "dyn/filter"]
        let eq = ["eq"] + (1...6).map { "eq/\($0)" } + ["geq"]
        let sends = (1...10).map { String(format: "mix/%02d", $0) }
        switch self {
        case .complete: return ["config/name", "config/color", "preamp"] + gate + eq + dynamics + ["mix"] + sends
        case .input: return ["preamp", "config/insrc", "config/rtnsrc"]
        case .gate: return gate
        case .compressor: return dynamics
        case .eq: return eq
        case .sends: return sends
        case .output: return ["mix/on", "mix/fader", "mix/lr", "mix/pan"]
        }
    }
}

public enum PasteScope: String, CaseIterable, Sendable, Identifiable {
    case config = "Config", input = "Preamp", gate = "Gate", eq = "EQ", dynamics = "Dynamics", mix = "Mix"
    public var id: Self { self }
    public var title: String { rawValue }
}

@MainActor
public enum SceneFiles {
    /// Every mixer node, in sync order (the `allpaths` table).
    public static func exportScene(store: ParameterStore) -> String {
        store.schema.syncPaths.compactMap { store.nodeText($0) }.joined(separator: "\n") + "\n"
    }

    /// Applies a scene locally and returns the node messages to push to the mixer.
    public static func importLines(_ text: String, into store: ParameterStore, pathRewrite: ((String) -> String?)? = nil) -> [OSCMessage] {
        var messages: [OSCMessage] = []
        let sceneNodes = Set(store.schema.syncPaths)
        for raw in text.split(whereSeparator: \.isNewline) {
            let tokens = NodeText.tokenize(String(raw))
            guard let first = tokens.first, !first.hasPrefix("#"), tokens.count > 1 else { continue }
            let original = first.hasPrefix("/") ? first : "/" + first
            let path: String
            if let pathRewrite {
                guard let mapped = pathRewrite(original) else { continue }
                path = mapped
            } else { path = original }

            let members = store.spec(path).map { [(path, $0)] } ?? store.nodeMembers(path)
            guard sceneNodes.contains(path) || sceneNodes.contains(path.oscParent), !members.isEmpty else { continue }
            var fields: [OSCMessage] = []
            for ((leaf, spec), token) in zip(members, tokens.dropFirst()) {
                guard let parsed = ValueText.parse(spec: spec, token: token) else { continue }
                if spec.isString { store.store(leaf, string: parsed.string) }
                else { store.store(leaf, index: parsed.index) }
                if let arg = store.oscArgument(leaf) { fields.append(OSCMessage(leaf, [arg])) }
            }
            if fields.count == members.count, let node = store.nodeMessage(path) { messages.append(node) }
            else { messages += fields }
        }
        return messages
    }

    nonisolated public static func channelBase(_ index: Int) -> String {
        // 0..15 ch, 16 aux, 17..20 fx returns, 21..26 bus, 27..30 fxsend, 31 lr
        switch index {
        case 0..<16: String(format: "/ch/%02d", index + 1)
        case 16: "/rtn/aux"
        case 17..<21: "/rtn/\(index - 16)"
        case 21..<27: "/bus/\(index - 20)"
        case 27..<31: "/fxsend/\(index - 26)"
        default: "/lr"
        }
    }

    public static func exportChannelPreset(store: ParameterStore, channel: String, scope: PresetScope) -> String {
        scope.nodeSuffixes.compactMap { suffix -> String? in
            let path = channel + "/" + suffix
            if let text = store.nodeText(path), let split = text.firstIndex(of: " ") { return "/" + suffix + text[split...] }
            guard let spec = store.spec(path) else { return nil }
            return "/" + suffix + " " + NodeText.encodeToken(spec: spec, index: store.index(path), string: store.string(path))
        }.joined(separator: "\n") + "\n"
    }

    private static func relativePresetPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        switch parts.first {
        case "ch", "bus", "rtn", "fxsend", "dca": return parts.dropFirst(2).joined(separator: "/")
        case "lr": return parts.dropFirst().joined(separator: "/")
        default: return parts.joined(separator: "/")
        }
    }

    /// Accept desktop relative paths and older absolute exports. Cross-size EQ recall keeps
    /// the two shelf bands and the middle two parametric bands on either console layout.
    public static func importChannelPreset(_ text: String, into store: ParameterStore, channel: String) -> [OSCMessage] {
        let bands = Set(text.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            let path = relativePresetPath(String(line.prefix { !$0.isWhitespace })).split(separator: "/")
            return path.count == 2 && path.first == "eq" ? Int(path[1]) : nil
        })
        let six = store.isNode(channel + "/eq/6")
        let fourToSix = six && bands == Set(1...4)
        let sixToFour = !six && bands == Set(1...6)
        var messages = fourToSix ? resetEQ(store: store, channel: channel) : []
        messages += importLines(text, into: store) { path in
            if path.hasPrefix("/headamp/") {
                guard channel.hasPrefix("/ch/") else { return nil }
                return store.model.headampIndex(forInputSource: store.index(channel + "/config/insrc")).map { String(format: "/headamp/%02d", $0) }
            }
            var suffix = relativePresetPath(path)
            if suffix.hasPrefix("eq/"), let n = Int(suffix.dropFirst(3)) {
                if fourToSix {
                    guard (1...4).contains(n) else { return nil }
                    suffix = "eq/\([1, 3, 4, 6][n - 1])"
                }
                if sixToFour {
                    guard let index = [1, 3, 4, 6].firstIndex(of: n) else { return nil }
                    suffix = "eq/\(index + 1)"
                }
            }
            let target = channel + "/" + suffix
            return store.isNode(target) || store.spec(target) != nil ? target : nil
        }
        return messages
    }

    public static func exportFXPreset(store: ParameterStore, slot: Int) -> String {
        let prefix = "/fx/\(slot)"
        var lines = ["type", "insert"].compactMap { leaf -> String? in
            let path = prefix + "/" + leaf
            guard let spec = store.spec(path) else { return nil }
            return leaf + " " + NodeText.encodeToken(spec: spec, index: store.index(path), string: "")
        }
        if let params = store.nodeText(prefix + "/par"), let space = params.firstIndex(of: " ") {
            lines.append("par" + params[space...])
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func importFXPreset(_ text: String, into store: ParameterStore, slot: Int) -> [OSCMessage] {
        guard (1...4).contains(slot) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
        func suffix(_ raw: Substring) -> String? {
            let path = raw.prefix { !$0.isWhitespace }.split(separator: "/")
            if path.first == "fx", path.count >= 2 { return path.dropFirst(2).joined(separator: "/") }
            return path.joined(separator: "/")
        }
        var result: [OSCMessage] = []
        for line in lines.filter({ suffix($0) != "par" }) + lines.filter({ suffix($0) == "par" }) {
            guard let component = suffix(line), ["", "type", "insert", "par"].contains(component) else { continue }
            let address = "/fx/\(slot)" + (component.isEmpty ? "" : "/" + component)
            result += importLines(String(line), into: store) { _ in address }
        }
        return result
    }

    /// Channel copy (node text of all channel sub-nodes).
    public static func copyChannel(store: ParameterStore, channel: String) -> String {
        exportChannelPreset(store: store, channel: channel, scope: .complete)
    }

    public static func paste(_ text: String, into store: ParameterStore, channel: String, scopes: Set<PasteScope>) -> [OSCMessage] {
        let filtered = text.split(whereSeparator: \.isNewline).filter { line in
            let p = relativePresetPath(String(line.prefix { !$0.isWhitespace })).split(separator: "/").first
            switch p {
            case "config": return scopes.contains(.config)
            case "preamp": return scopes.contains(.input)
            case "gate": return scopes.contains(.gate)
            case "eq", "geq": return scopes.contains(.eq)
            case "dyn": return scopes.contains(.dynamics)
            case "mix": return scopes.contains(.mix)
            default: return false
            }
        }.joined(separator: "\n")
        return importChannelPreset(filtered, into: store, channel: channel)
    }
}

/// Snapshot recall scope: 59 characters, '+' = recalled (Csnapshotcontrol::getSnapshotScopes).
public struct SnapshotScope: Equatable, Sendable {
    public static let count = 59
    public var flags: [Bool]

    public init(string: String) {
        let c = Array(string)
        flags = (0..<Self.count).map { $0 < c.count && c[$0] == "+" }
    }

    public init(all: Bool) { flags = Array(repeating: all, count: Self.count) }

    public var string: String { String(flags.map { $0 ? "+" : "-" }) }
    /// The original refuses an empty scope ("Please select at least one Snapshot Recall Scope!").
    public var isValid: Bool { flags.contains(true) }

    /// Scope filtering in the protocol simulator. The physical mixer performs its own recall.
    func includes(_ leaf: String, saved: ValueTable, model: MixerModel) -> Bool {
        if flags.allSatisfy({ $0 }) { return true }
        let path = leaf.split(separator: "/")
        guard let first = path.first else { return false }
        let number = path.count > 1 ? Int(path[1]) ?? 0 : 0
        switch first {
        case "config": return flags[58]
        case "routing": return flags[57]
        case "fx": return (1...4).contains(number) && flags[35 + number]
        case "headamp":
            return flags[41] && (0..<16).contains { ch in
                let source = saved.index[String(format: "/ch/%02d/config/insrc", ch + 1)] ?? ch
                return flags[ch] && model.headampIndex(forInputSource: source) == number
            }
        default: break
        }
        let strip: Int
        let suffix: ArraySlice<Substring>
        switch first {
        case "ch": strip = number - 1
        case "rtn": strip = path[1] == "aux" ? 16 : 16 + number
        case "bus": strip = 20 + number
        case "fxsend": strip = 26 + number
        case "lr": strip = 31
        case "dca": strip = 31 + number
        default: return false
        }
        guard (0..<36).contains(strip), flags[strip] else { return false }
        suffix = path.dropFirst(first == "lr" ? 1 : 2)
        switch suffix.first {
        case "config": return (suffix.last == "insrc" || suffix.last == "rtnsrc") ? flags[40] : flags[42]
        case "preamp": return suffix.last == "rtnsw" ? flags[40] : flags[41]
        case "eq", "geq": return flags[43]
        case "gate", "dyn", "insert": return flags[44]
        case "mix":
            if suffix.count > 2, let send = Int(suffix[suffix.index(after: suffix.startIndex)]), (1...10).contains(send) { return flags[44 + send] }
            return suffix.last == "on" ? flags[56] : flags[55]
        case "on": return flags[56]
        case "fader": return flags[55]
        default: return flags[42]
        }
    }

}
