import Foundation

public struct RoutingPreset: Decodable, Identifiable, Sendable {
    public let title: String
    public let lines: [String]
    public var id: String { title }
}

public struct BuiltinPresets: Decodable, Sendable {
    public struct Curve: Decodable, Sendable { public let lines: [String] }
    public let ultranet, usbReturn, usbSend: [RoutingPreset]
    public let eqInit4, eqInit6: Curve

    public static let shared: BuiltinPresets = {
        guard let url = Bundle.module.url(forResource: "builtin-presets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let presets = try? JSONDecoder().decode(Self.self, from: data) else {
            preconditionFailure("Missing built-in mixer presets")
        }
        return presets
    }()
}

public enum RoutingScope: String, CaseIterable, Identifiable, Sendable {
    case inputs = "Channel inputs", usbReturn = "USB returns", usbSend = "USB sends"
    case ultranet = "Ultranet", aux = "Aux outputs", main = "Main and phones"
    public var id: Self { self }

    public static func available(on model: MixerModel) -> [Self] {
        model.hasUSBAudioInterface ? allCases : [.inputs, .aux, .main]
    }

    fileprivate static func scope(of leaf: String, model: MixerModel) -> Self? {
        let p = leaf.split(separator: "/")
        if p.count == 4, p[0] == "routing" {
            switch p[1] {
            case "usb": return model.hasUSBAudioInterface ? .usbSend : nil
            case "p16": return model.hasUltranetAndUSBRouting ? .ultranet : nil
            case "aux": return (Int(p[2]) ?? Int.max) <= model.auxOutputCount ? .aux : nil
            case "main": return .main
            default: return nil
            }
        }
        guard p.count == 4, p[0] == "ch" || (p[0] == "rtn" && p[1] == "aux") else { return nil }
        if p[2] == "config", p[3] == "insrc" { return .inputs }
        if model.hasUSBAudioInterface, (p[2] == "preamp" && p[3] == "rtnsw") || (p[2] == "config" && p[3] == "rtnsrc") { return .usbReturn }
        return nil
    }
}

extension SceneFiles {
    public static func exportRouting(store: ParameterStore) -> String {
        var lines: [String] = []
        for node in store.schema.syncPaths {
            let members = store.nodeMembers(node).filter { RoutingScope.scope(of: $0.0, model: store.model) != nil }
            if node.hasPrefix("/routing/"), !members.isEmpty, let text = store.nodeText(node) {
                lines.append(text)
            } else {
                for (leaf, spec) in members {
                    let token = NodeText.encodeToken(spec: spec, index: store.index(leaf), string: store.string(leaf))
                    lines.append(String(leaf.dropFirst()) + " " + token)
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Accept both desktop routing leaves and older exports containing whole config nodes.
    /// Send only the selected fields, including when a file includes unrelated strip settings.
    public static func importRouting(_ text: String, into store: ParameterStore,
                                     scopes: Set<RoutingScope> = Set(RoutingScope.allCases)) -> [OSCMessage] {
        var messages: [OSCMessage] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = NodeText.tokenize(String(line))
            guard let first = tokens.first else { continue }
            let path = first.hasPrefix("/") ? first : "/" + first
            let members = store.spec(path).map { [(path, $0)] } ?? store.nodeMembers(path)
            for ((leaf, spec), token) in zip(members, tokens.dropFirst()) {
                guard let scope = RoutingScope.scope(of: leaf, model: store.model), scopes.contains(scope),
                      let v = ValueText.parse(spec: spec, token: token) else { continue }
                store.store(leaf, index: v.index)
                if let arg = store.oscArgument(leaf) { messages.append(OSCMessage(leaf, [arg])) }
            }
        }
        return messages
    }

    public static func resetEQ(store: ParameterStore, channel: String) -> [OSCMessage] {
        guard store.isNode(channel + "/eq/4") else { return [] }
        let presets = BuiltinPresets.shared
        let curve = store.isNode(channel + "/eq/6") ? presets.eqInit6 : presets.eqInit4
        return importLines(curve.lines.joined(separator: "\n"), into: store) { channel + $0 }
    }
}
