import Darwin
import Foundation
import SystemConfiguration

/// Finds the default IPv4 gateway (the home router) and its hardware
/// address.
public enum GatewayResolver {
    public static func current() -> GatewayInfo? {
        guard let store = SCDynamicStoreCreate(nil, "Whirr" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = dict["Router"] as? String else { return nil }
        return GatewayInfo(ip: router, mac: macAddress(for: router))
    }

    /// Looks `ip` up in the kernel ARP table via the routing sysctl
    /// (`NET_RT_FLAGS` + `RTF_LLINFO`) — the same data `arp -n` prints,
    /// without spawning a process.
    static func macAddress(for ip: String) -> String? {
        var target = in_addr()
        guard inet_pton(AF_INET, ip, &target) == 1 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> String? in
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: rt_msghdr.self)
                defer { offset += Int(header.rtm_msglen) }
                guard header.rtm_msglen > 0 else { return nil }
                let saOffset = offset + MemoryLayout<rt_msghdr>.size
                let sin = raw.load(fromByteOffset: saOffset, as: sockaddr_in.self)
                guard sin.sin_addr.s_addr == target.s_addr else { continue }
                // The link-layer sockaddr follows, 4-byte aligned.
                let sinLen = Int(sin.sin_len)
                let dlOffset = saOffset + (sinLen > 0 ? (sinLen + 3) & ~3 : 4)
                let dl = raw.load(fromByteOffset: dlOffset, as: sockaddr_dl.self)
                guard dl.sdl_alen == 6 else { return nil }
                let macStart = dlOffset + 8 + Int(dl.sdl_nlen)  // sdl_data begins at offset 8
                let bytes = (0..<6).map { raw[macStart + $0] }
                return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
            return nil
        }
    }
}
