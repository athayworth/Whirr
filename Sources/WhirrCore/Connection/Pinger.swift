import Darwin
import Foundation

public protocol Pinging: Sendable {
    /// One echo request; returns RTT in ms, or nil on timeout/error.
    func ping(_ host: String, timeout: TimeInterval) async -> Double?
}

/// ICMP echo over an unprivileged datagram socket
/// (`SOCK_DGRAM` + `IPPROTO_ICMP`) — works without root on macOS.
/// Each call opens its own socket so concurrent pings to different hops
/// never read each other's replies.
public struct ICMPPinger: Pinging {
    public init() {}

    public func ping(_ host: String, timeout: TimeInterval) async -> Double? {
        await Task.detached(priority: .utility) {
            Self.blockingPing(host, timeout: timeout)
        }.value
    }

    static func blockingPing(_ host: String, timeout: TimeInterval) -> Double? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let identifier = UInt16.random(in: 1...UInt16.max)
        let sequence = UInt16.random(in: 1...UInt16.max)
        var packet: [UInt8] = [8, 0, 0, 0,
                               UInt8(identifier >> 8), UInt8(identifier & 0xff),
                               UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        packet += Array(repeating: 0x57, count: 24)  // small payload
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        let deadline = start + UInt64(timeout * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32((deadline - now) / 1_000_000)
            guard poll(&pfd, 1, max(waitMs, 1)) > 0 else { return nil }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            if isMatchingReply(Array(buffer[0..<n]), sequence: sequence) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                return Double(elapsed) / 1_000_000
            }
        }
    }

    /// macOS may or may not prepend the IPv4 header on datagram ICMP
    /// sockets; accept both. Match on echo-reply type and our sequence
    /// number (the kernel may rewrite the identifier).
    static func isMatchingReply(_ bytes: [UInt8], sequence: UInt16) -> Bool {
        var offset = 0
        if let first = bytes.first, first >> 4 == 4 {
            offset = Int(first & 0x0f) * 4
        }
        guard bytes.count >= offset + 8 else { return false }
        let type = bytes[offset]
        let seq = UInt16(bytes[offset + 6]) << 8 | UInt16(bytes[offset + 7])
        return type == 0 && seq == sequence
    }

    /// RFC 1071 internet checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
