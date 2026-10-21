#if canImport(Darwin)
import Darwin
#endif
public import Foundation

/// Adds the haild running on this Mac to the Mac station's hosts, once (#266). It only ever adds a loopback
/// endpoint built from this Mac's own `host.json`: never a discovered, remote or tailnet host.
public enum LocalHostBootstrap {
    /// Set once the local host has been offered, added or not, so a local host the user removes stays removed.
    public static let offeredKey = "hailing-station.local-host-offered.v1"
    public static let endpointID: HostEndpoint.Identifier = "this-mac"
    public static let endpointName = "This Mac"
    /// `host.json` is a few hundred bytes; anything far larger is not the daemon's config.
    static let configByteLimit = 64 * 1024

    /// What to restore: `hosts` when they changed, and whether the offer is now spent.
    public struct Decision: Equatable, Sendable {
        public let hosts: [HostEndpoint]?
        public let offered: Bool
    }

    #if os(macOS)
    /// The daemon's configuration on this Mac (`~/.config/hail/host.json`). Only `bind` and `port` are read.
    public static var hostConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hail/host.json")
    }
    #endif

    /// Reads a config file without following a symlink, refusing anything but a regular file (a FIFO would block)
    /// and anything over the size limit. Call it off the main actor.
    public static func readConfig(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= configByteLimit else { return nil }
        var buffer = [UInt8](repeating: 0, count: configByteLimit + 1)
        var total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(descriptor, base + total, raw.count - total)
            }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            total += count
        }
        guard total <= configByteLimit else { return nil }
        return Data(buffer[..<total])
    }

    /// The loopback endpoint for the daemon `host.json` describes. Nil without a readable config, with a port
    /// outside 1–65535, or when `bind` is anything but a loopback or wildcard IP literal: haild does not answer
    /// on loopback then, and a hostname would go to DNS.
    public static func endpoint(hostConfig: Data?) -> HostEndpoint? {
        guard let hostConfig,
              let object = try? JSONSerialization.jsonObject(with: hostConfig) as? [String: Any],
              let bind = object["bind"] as? String,
              let port = object["port"] as? Int, (1...65_535).contains(port),
              let host = loopbackHost(forBind: bind),
              let url = URL(string: "ws://\(host):\(port)") else { return nil }
        return try? HostEndpoint(id: endpointID, name: endpointName, url: url)
    }

    /// Adds the local endpoint the first time it is offered, unless a saved host already points at loopback.
    /// Either way the offer is then spent, so a local host the user later removes is not added again.
    public static func restore(
        _ saved: [HostEndpoint], local: HostEndpoint?, alreadyOffered: Bool
    ) -> Decision {
        guard !alreadyOffered, let local else { return Decision(hosts: nil, offered: alreadyOffered) }
        let present = saved.contains { $0.id == local.id || isLoopback($0.url) }
        return Decision(hosts: present ? nil : saved + [local], offered: true)
    }

    /// The canonical loopback address to reach a daemon bound to `bind`, from IP literals only.
    static func loopbackHost(forBind bind: String) -> String? {
        if let v4 = ipv4(bind) {
            if v4 == [0, 0, 0, 0] { return "127.0.0.1" }
            return v4[0] == 127 ? v4.map(String.init).joined(separator: ".") : nil
        }
        if let v6 = ipv6(bind) {
            let any = [UInt8](repeating: 0, count: 16)
            var loopback = any
            loopback[15] = 1
            return v6 == any || v6 == loopback ? "[::1]" : nil // Not mapped or compatible IPv4 forms.
        }
        return nil
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard var host = url.host()?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" { return true }
        if let v4 = ipv4(host) { return v4[0] == 127 }
        if let v6 = ipv6(host) { return v6 == [UInt8](repeating: 0, count: 15) + [1] }
        return false
    }

    /// Strict dotted-quad parsing: four decimal octets of digits only, without leading zeros (Darwin's `inet_pton`
    /// accepts "127.00.0.1"), then `inet_pton`, which refuses signs, short forms and hostnames.
    private static func ipv4(_ text: String) -> [UInt8]? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ octet in
            !octet.isEmpty && octet.count <= 3 && octet.allSatisfy { ("0"..."9").contains($0) }
                && (octet.count == 1 || octet.first != "0")
        }) else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}
