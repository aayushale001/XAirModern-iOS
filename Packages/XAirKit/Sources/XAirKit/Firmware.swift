import Foundation

/// Firmware update over UDP 10018, replicating ConnectPage::UpdateFirmware and
/// ConnectPage::run (PROTOCOL.md §9). Never run against real hardware without
/// the owner's explicit authorization; tests use a fake updater only.
public enum FirmwareError: Error, Equatable, Sendable {
    case notAnUpdateFile
    case wrongHardwareGeneration(needsV2File: Bool)
    case fileTooSmall
    case noHandshake
    case chunkRejected(offset: Int)
    case programmingFailed
    case cancelled
    case notAuthorized
}

public struct FirmwareFileCheck: Sendable, Equatable {
    public let isV2File: Bool

    /// `.update` extension; a name containing "V2"/"v2" requires V2 hardware and vice versa.
    public static func validate(fileName: String, size: Int, hardwareIsV2: Bool) -> Result<FirmwareFileCheck, FirmwareError> {
        guard fileName.lowercased().hasSuffix(".update") else { return .failure(.notAnUpdateFile) }
        let stem = String(fileName.dropLast(".update".count))
        let v2 = stem.contains("V2") || stem.contains("v2")
        if v2 != hardwareIsV2 { return .failure(.wrongHardwareGeneration(needsV2File: hardwareIsV2)) }
        guard size > 0 else { return .failure(.fileTooSmall) }
        return .success(FirmwareFileCheck(isV2File: v2))
    }
}

public final class FirmwareUpdater: @unchecked Sendable {
    public static let port: UInt16 = 10018
    public static let chunkSize = 1024
    public static let packetSize = 1032
    public static let programThreshold = 0x2800

    public enum Phase: Equatable, Sendable { case idle, handshake, transferring(Double), programming, rebooting, failed(String) }

    private let transport: DatagramTransport
    private let host: String
    private let port: UInt16
    private let lock = NSLock()
    private var replies: [UInt8] = []
    private var waiter: CheckedContinuation<UInt8?, Never>?
    private var waiterID = 0
    private var cancelled = false

    public init(transport: DatagramTransport, host: String, port: UInt16 = FirmwareUpdater.port) {
        self.transport = transport
        self.host = host
        self.port = port
    }

    public func cancel() { lock.withLock { cancelled = true } }

    /// Builds the exact packet sequence the original sends, including its reuse of a
    /// 1024-byte buffer: the final packet is always 1032 bytes and its tail keeps the
    /// previous chunk's bytes.
    public static func packets(for data: Data) -> [Data] {
        var out: [Data] = []
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let n = min(chunkSize, bytes.count - offset)
            buffer.replaceSubrange(0..<n, with: bytes[offset..<offset + n])
            var p = Data("sW**".utf8)
            var le = UInt32(offset).littleEndian
            withUnsafeBytes(of: &le) { p.append(contentsOf: $0) }
            p.append(contentsOf: buffer)
            out.append(p)
            offset += chunkSize
        }
        return out
    }

    public func run(firmware: Data, authorized: Bool, progress: @escaping @Sendable (Phase) -> Void) async throws {
        guard authorized else { throw FirmwareError.notAuthorized }
        try transport.start { [weak self] dg in self?.receive(dg) }
        defer { transport.stop() }
        progress(.handshake)
        try transport.send(Data("us**".utf8), to: host, port: port)
        guard await nextReply(timeoutMs: 500) == UInt8(ascii: "Y") else { progress(.failed("No handshake")); throw FirmwareError.noHandshake }
        let pkts = Self.packets(for: firmware)
        for (i, p) in pkts.enumerated() {
            if lock.withLock({ cancelled }) { throw FirmwareError.cancelled }
            var ack: UInt8?
            for _ in 0..<3 {
                try transport.send(p, to: host, port: port)
                ack = await nextReply(timeoutMs: 500)
                if ack != nil { break }
            }
            guard ack == UInt8(ascii: "Y") else {
                progress(.failed("Update failed, please try again!"))
                throw FirmwareError.chunkRejected(offset: i * Self.chunkSize)
            }
            progress(.transferring(Double(min((i + 1) * Self.chunkSize, firmware.count)) / Double(firmware.count)))
        }
        let sent = pkts.count * Self.chunkSize
        guard sent > Self.programThreshold else { progress(.failed("Update failed, please try again!")); throw FirmwareError.programmingFailed }
        progress(.programming)
        try transport.send(Data("sUpd".utf8), to: host, port: port)
        try await Task.sleep(for: .milliseconds(500))
        guard await nextReply(timeoutMs: 1 + 32 * pkts.count) == UInt8(ascii: "Y") else {
            progress(.failed("Update failed, please try again!"))
            throw FirmwareError.programmingFailed
        }
        try transport.send(Data("ur**".utf8), to: host, port: port)
        progress(.rebooting)
    }

    private func receive(_ dg: Datagram) {
        guard let first = dg.data.first else { return }
        let w: CheckedContinuation<UInt8?, Never>? = lock.withLock {
            if let w = waiter { waiter = nil; return w }
            replies.append(first)
            return nil
        }
        w?.resume(returning: first)
    }

    private func popOrPark(_ c: CheckedContinuation<UInt8?, Never>) -> (reply: UInt8?, id: Int) {
        lock.withLock {
            if !replies.isEmpty { return (replies.removeFirst(), 0) }
            waiterID += 1
            waiter = c
            return (nil, waiterID)
        }
    }

    /// Only the timeout belonging to the parked wait may cancel it.
    private func takeWaiter(id: Int) -> CheckedContinuation<UInt8?, Never>? {
        lock.withLock {
            guard waiterID == id, let w = waiter else { return nil }
            waiter = nil
            return w
        }
    }

    private func nextReply(timeoutMs: Int) async -> UInt8? {
        await withCheckedContinuation { (c: CheckedContinuation<UInt8?, Never>) in
            let parked = popOrPark(c)
            if let r = parked.reply { c.resume(returning: r); return }
            let id = parked.id
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                self?.takeWaiter(id: id)?.resume(returning: nil)
            }
        }
    }
}
