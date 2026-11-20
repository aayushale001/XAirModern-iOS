import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct Datagram: Sendable {
    public let data: Data
    public let host: String
    public let port: UInt16
}

public enum TransportError: Error, Equatable, Sendable {
    case socket(Int32)
    case bind(Int32)
    case badAddress(String)
    case send(Int32)
    case notStarted
}

/// Isolated datagram transport, so the session can run over real UDP or an
/// in-process loopback to the simulator.
public protocol DatagramTransport: AnyObject, Sendable {
    func start(onReceive: @escaping @Sendable (Datagram) -> Void) throws
    func send(_ data: Data, to host: String, port: UInt16) throws
    func stop()
}

/// UDP socket configured like the original JUCE DatagramSocket
/// (SO_BROADCAST=1, SO_REUSEADDR=1, 64 KiB buffers, INADDR_ANY:0).
public final class UDPSocketTransport: DatagramTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "xair.udp")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let bindHost: String?
    private let bindPort: UInt16
    public private(set) var localPort: UInt16 = 0

    /// - Parameters: bindHost/bindPort let the simulator listen on 127.0.0.1:10024.
    public init(bindHost: String? = nil, bindPort: UInt16 = 0) {
        self.bindHost = bindHost
        self.bindPort = bindPort
    }

    deinit { stop() }

    public func start(onReceive: @escaping @Sendable (Datagram) -> Void) throws {
        try queue.sync {
            guard fd < 0 else { return }
            let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard s >= 0 else { throw TransportError.socket(errno) }
            var one: Int32 = 1
            var buf: Int32 = 65536
            setsockopt(s, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = bindPort.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            if let bindHost { inet_pton(AF_INET, bindHost, &addr.sin_addr) }
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard r == 0 else { let e = errno; close(s); throw TransportError.bind(e) }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
            }
            localPort = UInt16(bigEndian: bound.sin_port)
            let flags = fcntl(s, F_GETFL)
            _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
            fd = s
            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            src.setEventHandler { [weak self] in self?.drain(onReceive) }
            src.setCancelHandler { close(s) }
            source = src
            src.resume()
        }
    }

    private func drain(_ onReceive: @Sendable (Datagram) -> Void) {
        var buffer = [UInt8](repeating: 0, count: OSCCodec.maxPacketSize)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, OSCCodec.maxPacketSize, 0, $0, &len)
                    }
                }
            }
            if n <= 0 { return }
            var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = from.sin_addr
            inet_ntop(AF_INET, &a, &ipbuf, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: ipbuf)
            onReceive(Datagram(data: Data(buffer[0..<n]), host: host, port: UInt16(bigEndian: from.sin_port)))
        }
    }

    public func send(_ data: Data, to host: String, port: UInt16) throws {
        try queue.sync {
            guard fd >= 0 else { throw TransportError.notStarted }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw TransportError.badAddress(host) }
            let r = data.withUnsafeBytes { raw in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if r < 0 { throw TransportError.send(errno) }
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            fd = -1
        }
    }
}

public enum NetworkInterfaces {
    /// Discovery targets in the original order (ConnectPage::findDevices):
    /// 192.168.1.1, up to 5 IPv4 subnet broadcasts (addr | ~mask, skipping
    /// addresses whose text starts with "127.0.0.1"), then 255.255.255.255.
    public static func discoveryTargets() -> [String] {
        var targets = ["192.168.1.1"]
        targets.append(contentsOf: subnetBroadcasts().prefix(5))
        targets.append("255.255.255.255")
        return targets
    }

    public static func subnetBroadcasts() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  let nm = cur.pointee.ifa_netmask else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if ipString(addr).hasPrefix("127.0.0.1") { continue }
            let bcast = addr | ~mask
            result.append(ipString(bcast))
        }
        return result
    }

    /// Local IPv4 addresses (for status display).
    public static func localAddresses() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let s = ipString(addr)
            if !s.hasPrefix("127.") { result.append(s) }
        }
        return result
    }

    static func ipString(_ s_addr: in_addr_t) -> String {
        var a = in_addr(s_addr: s_addr)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    public static func isValidIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }
}
