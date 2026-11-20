import Foundation

public struct FXIndicator: Identifiable, Sendable {
    public let label: String
    public let value: Int
    public let maximum: Int
    public var id: String { label }
}

extension MeterStore {
    /// The ten internal registers per slot use algorithm-specific scales.
    public func effectIndicators(slot: Int, type: String, store: ParameterStore) -> [FXIndicator] {
        guard (1...4).contains(slot) else { return [] }
        let start = (slot - 1) * 14 + 2
        func indicator(_ offset: Int, _ label: String, _ maximum: Int,
                       _ convert: (Float) -> Int) -> FXIndicator? {
            guard let raw = raw(.effects, start + offset) else { return nil }
            let value = convert(Float(raw) * 0.000488)
            return FXIndicator(label: label, value: max(0, min(maximum, value)), maximum: maximum)
        }
        switch type {
        case "LIM":
            return ["L", "R"].enumerated().compactMap { i, side in
                indicator(i, "Limiter " + side, 20) { Int(($0 * 192).rounded()) }
            }
        case "DES", "DES2":
            return ["Low A", "High A", "Low B", "High B"].enumerated().compactMap { i, band in
                indicator(i, band, 7) { value in
                    [Float(0.01), 0.1, 0.2, 0.35, 0.5, 0.7, 0.9].filter { value > $0 }.count
                }
            }
        case "FAC", "FAC1M", "FAC2":
            let channels = type == "FAC" ? ["Stereo"] : type == "FAC1M" ? ["Mid", "Side"] : ["A", "B"]
            return channels.enumerated().compactMap { i, side in
                indicator(i, "VU " + side, 22) { max(0, Int($0 * 34.1333)) + 1 }
            }
        case "CMB", "CMB2":
            let sides = type == "CMB2" ? 2 : 1
            return (0..<sides).flatMap { side -> [FXIndicator] in
                let base = side * 29
                let mode = store.index(String(format: "/fx/%d/par/%02d", slot, base + 29))
                let modeName = ["GR", "Peak", "SBC"][min(max(0, mode), 2)]
                return (0..<5).compactMap { band in
                    let label = "\(modeName) \(band + 1)" + (sides == 1 ? "" : (side == 0 ? " A" : " B"))
                    return indicator(2 * band + side, label, 20) { v in
                        if mode == 2 { return 10 + Int(v * 6 + 0.5) }
                        if mode == 1 {
                            guard v > 0 else { return 0 }
                            let dB = 20 * log10(v)
                            let thresholds: [Float] = [-54, -51, -48, -45, -42, -39, -36, -33, -30, -27, -24, -21, -18, -15, -12, -10, -8, -6, -4, -2, -0.2]
                            return thresholds.filter { dB > $0 }.count
                        }
                        let trim = store.physical(String(format: "/fx/%d/par/%02d", slot, base + 15 + band * 3))
                        return 10 - Int(trim - 0.5) - Int(v * 6 + 0.5)
                    }
                }
            }
        default: return []
        }
    }
}
