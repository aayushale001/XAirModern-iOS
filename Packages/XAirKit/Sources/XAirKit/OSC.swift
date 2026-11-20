import Foundation

/// One OSC argument. X-Air uses only `i`, `f`, `s` and `b` (see PROTOCOL.md §2).
public enum OSCArgument: Sendable, Equatable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob(Data)

    public var typeTag: Character {
        switch self {
        case .int: "i"
        case .float: "f"
        case .string: "s"
        case .blob: "b"
        }
    }
}

/// An OSC message. The address is kept verbatim because X-Air replies with
/// addresses that have no leading slash (`node`, `meters/1`).
public struct OSCMessage: Sendable, Equatable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public var typeTags: String { "," + String(arguments.map(\.typeTag)) }
}

public enum OSCError: Error, Equatable, Sendable {
    case packetTooLarge(Int)
    case misaligned(Int)
    case unterminatedString(offset: Int)
    case missingTypeTags
    case truncatedArgument(Character)
    case unsupportedTypeTag(Character)
    case blobTooLarge(Int)
    case bundlesNotSupported
}

public enum OSCCodec {
    /// Largest datagram the original app reads (UdpConnection::run, 1500 bytes).
    public static let maxPacketSize = 1500

    // MARK: Encoding (oscpack-compatible: 4-byte aligned, big-endian)

    public static func encode(_ message: OSCMessage) -> Data {
        var out = Data()
        out.reserveCapacity(64)
        appendString(message.address, to: &out)
        appendString(message.typeTags, to: &out)
        for arg in message.arguments {
            switch arg {
            case .int(let v):
                appendUInt32(UInt32(bitPattern: v), to: &out)
            case .float(let v):
                appendUInt32(v.bitPattern, to: &out)
            case .string(let s):
                appendString(s, to: &out)
            case .blob(let d):
                appendUInt32(UInt32(d.count), to: &out)
                out.append(d)
                let pad = (4 - d.count % 4) % 4
                if pad > 0 { out.append(contentsOf: [UInt8](repeating: 0, count: pad)) }
            }
        }
        return out
    }

    private static func appendString(_ s: String, to out: inout Data) {
        let bytes = Array(s.utf8)
        out.append(contentsOf: bytes)
        let total = bytes.count + 1
        let padded = (total + 3) & ~3
        out.append(contentsOf: [UInt8](repeating: 0, count: padded - bytes.count))
    }

    private static func appendUInt32(_ v: UInt32, to out: inout Data) {
        withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) }
    }

    // MARK: Decoding (bounded; rejects anything the original would reject)

    public static func decode(_ data: Data) throws -> OSCMessage {
        guard data.count <= maxPacketSize else { throw OSCError.packetTooLarge(data.count) }
        // UdpConnection::run drops packets whose length is not a multiple of 4.
        guard data.count % 4 == 0, !data.isEmpty else { throw OSCError.misaligned(data.count) }
        let bytes = [UInt8](data)
        if bytes.first == UInt8(ascii: "#") { throw OSCError.bundlesNotSupported }
        var offset = 0
        let address = try readString(bytes, &offset)
        guard offset < bytes.count else { return OSCMessage(address) }
        guard bytes[offset] == UInt8(ascii: ",") else { throw OSCError.missingTypeTags }
        let tags = try readString(bytes, &offset)
        var args: [OSCArgument] = []
        args.reserveCapacity(tags.count)
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard offset + 4 <= bytes.count else { throw OSCError.truncatedArgument(tag) }
                args.append(.int(Int32(bitPattern: readUInt32(bytes, offset))))
                offset += 4
            case "f":
                guard offset + 4 <= bytes.count else { throw OSCError.truncatedArgument(tag) }
                args.append(.float(Float(bitPattern: readUInt32(bytes, offset))))
                offset += 4
            case "s":
                args.append(.string(try readString(bytes, &offset)))
            case "b":
                guard offset + 4 <= bytes.count else { throw OSCError.truncatedArgument(tag) }
                let size = Int(readUInt32(bytes, offset))
                offset += 4
                guard size <= maxPacketSize, offset + size <= bytes.count else { throw OSCError.blobTooLarge(size) }
                args.append(.blob(Data(bytes[offset..<offset + size])))
                offset += (size + 3) & ~3
            default:
                throw OSCError.unsupportedTypeTag(tag)
            }
        }
        return OSCMessage(address, args)
    }

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    private static func readString(_ b: [UInt8], _ offset: inout Int) throws -> String {
        let start = offset
        guard let end = b[start...].firstIndex(of: 0) else { throw OSCError.unterminatedString(offset: start) }
        let s = String(decoding: b[start..<end], as: UTF8.self)
        offset = (end + 4) & ~3
        if offset > b.count { throw OSCError.unterminatedString(offset: start) }
        return s
    }
}

public extension OSCArgument {
    var intValue: Int? {
        switch self {
        case .int(let v): Int(v)
        case .float(let f): Int(f)
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
