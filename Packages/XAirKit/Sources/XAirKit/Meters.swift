import Foundation
import Observation

/// Decodes `meters/N ,b` blobs: `[int32 LE count][count x int16 LE]`, values are dB*256.
/// The original requires blobSize/2-2 == count == meterbatchsize[N] (OscCom::handleMessage).
public enum MeterDecoder {
    public static func blockIndex(address: String) -> Int? {
        // "meters/1" or "meters/10"; the original accepts no leading slash here.
        let a = address.hasPrefix("/") ? String(address.dropFirst()) : address
        guard a.hasPrefix("meters/"), let n = Int(a.dropFirst(7)), n >= 0, n < 10 else { return nil }
        return n
    }

    public static func decode(blob: Data, expectedCount: Int?) -> [Int16]? {
        guard blob.count >= 4 else { return nil }
        let b = [UInt8](blob)
        let count = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        guard count >= 0, count <= 100, 4 + count * 2 == b.count else { return nil }
        if let expectedCount, expectedCount != count { return nil }
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let lo = UInt16(b[4 + 2 * i]), hi = UInt16(b[5 + 2 * i])
            out[i] = Int16(bitPattern: lo | hi << 8)
        }
        return out
    }

    public static func encode(values: [Int16]) -> Data {
        var d = Data()
        var c = UInt32(values.count).littleEndian
        withUnsafeBytes(of: &c) { d.append(contentsOf: $0) }
        for v in values {
            var le = UInt16(bitPattern: v).littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        return d
    }

    @inlinable public static func dB(_ raw: Int16) -> Float { Float(raw) / 256 }
}

/// Known meter block layouts (PROTOCOL.md §7). Labels are evidence-backed where marked.
public enum MeterBlock: Int, CaseIterable, Sendable {
    case selectedChannel = 0
    case mixer = 1             // 40 values (FaderSection + MeterIO, observed)
    case inputs = 2            // 36 values (MeterIO, observed)
    case effects = 3
    case rta = 4               // 100 values (RTA)
    case outputs = 5
    case dynamics = 6
    case automix = 7
    case dca = 8
    case recorder = 9

    public static func compressorIndex(strip: Int) -> Int? {
        switch strip {
        case 0..<16: return 16 + strip
        case 21..<27: return 32 + strip - 21
        case 31: return 38
        default: return nil
        }
    }

    public static let mixerChannelRange = 0..<16
    public static let mixerAux = 16          // L, R
    public static let mixerFxReturn = 18     // 4 pairs
    public static let mixerBus = 26          // 6 mono
    public static let mixerFxSend = 32       // 4 mono
    public static let mixerMain = 36         // L, R
    public static let mixerMonitor = 38      // solo/monitor L, R
}

@MainActor
@Observable
public final class MeterStore {
    public private(set) var blocks: [[Int16]] = Array(repeating: [], count: 10)
    public private(set) var lastUpdate: [Date?] = Array(repeating: nil, count: 10)
    public private(set) var packetCount = 0

    public init() {}

    public func update(block: Int, values: [Int16], at date: Date = Date()) {
        guard block >= 0, block < 10 else { return }
        blocks[block] = values
        lastUpdate[block] = date
        packetCount &+= 1
    }

    public func raw(_ block: MeterBlock, _ i: Int) -> Int16? {
        let b = blocks[block.rawValue]
        return i >= 0 && i < b.count ? b[i] : nil
    }

    public func dB(_ block: MeterBlock, _ i: Int) -> Float {
        guard let r = raw(block, i) else {
            return block == .dynamics || block == .automix || (block == .selectedChannel && (2...3).contains(i)) ? 0 : -90
        }
        return MeterDecoder.dB(r)
    }

    public func reset() {
        blocks = Array(repeating: [], count: 10)
        lastUpdate = Array(repeating: nil, count: 10)
        packetCount = 0
    }
}
