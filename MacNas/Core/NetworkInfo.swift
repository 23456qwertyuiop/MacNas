//
//  NetworkInfo.swift
//  MacNas
//
//  局域网地址探测与端口占用检测。
//

import Foundation

enum NetworkInfo {
    /// 当前可用于局域网访问的 IPv4 地址（优先 en0 / en1）
    static func localIPv4Addresses() -> [String] {
        var results: [(name: String, address: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            if isUp, !isLoopback, interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                if result == 0 {
                    let address = String(cString: hostname)
                    if address != "127.0.0.1", !address.hasPrefix("169.254.") {
                        results.append((String(cString: interface.ifa_name), address))
                    }
                }
            }
            pointer = interface.ifa_next
        }

        let sorted = results.sorted { lhs, rhs in
            func rank(_ name: String) -> Int {
                if name == "en0" { return 0 }
                if name == "en1" { return 1 }
                if name.hasPrefix("en") { return 2 }
                if name.hasPrefix("bridge") { return 3 }
                return 4
            }
            return rank(lhs.name) < rank(rhs.name)
        }
        return sorted.map(\.address)
    }

    static func primaryIPv4Address() -> String? { localIPv4Addresses().first }

    /// 端口是否可以被绑定（能否作为服务端口）
    static func isPortAvailable(_ port: UInt16) -> Bool {
        guard port > 0 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")

        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
