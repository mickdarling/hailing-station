public import Foundation

/// Adds the haild running on this Mac to the Mac station's hosts, once (#266). It only ever adds a loopback
/// endpoint built from this Mac's own `host.json`: never a discovered, remote or tailnet host.
public enum LocalHostBootstrap {
    /// Set after the first offer, so a local host the user removes stays removed.
    public static let offeredKey = "hailing-station.local-host-offered.v1"
    public static let endpointID: HostEndpoint.Identifier = "this-mac"
    public static let endpointName = "This Mac"

    /// The daemon's configuration on this Mac (`~/.config/hail/host.json`). Only `bind` and `port` are read.
    public static var hostConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hail/host.json")
    }

    /// The loopback endpoint for the daemon `host.json` describes. Nil without a readable config, with a port
    /// outside 1–65535, or when `bind` is a specific non-loopback address, which haild does not answer on loopback.
    public static func endpoint(hostConfig: Data?) -> HostEndpoint? {
        guard let hostConfig,
              let object = try? JSONSerialization.jsonObject(with: hostConfig) as? [String: Any],
              let bind = object["bind"] as? String,
              let port = object["port"] as? Int, (1...65_535).contains(port),
              let host = loopbackHost(forBind: bind),
              let url = URL(string: "ws://\(host):\(port)") else { return nil }
        return try? HostEndpoint(id: endpointID, name: endpointName, url: url)
    }

    /// The hosts to restore: `saved` plus the local endpoint, the first time only, and not when a saved host
    /// already points at loopback. Nil when nothing changes.
    public static func adding(
        _ local: HostEndpoint?, to saved: [HostEndpoint], alreadyOffered: Bool
    ) -> [HostEndpoint]? {
        guard !alreadyOffered, let local,
              !saved.contains(where: { $0.id == local.id || isLoopback($0.url) }) else { return nil }
        return saved + [local]
    }

    static func loopbackHost(forBind bind: String) -> String? {
        switch bind {
        case "0.0.0.0": return "127.0.0.1"
        case "::", "::1": return "[::1]"
        default:
            let octets = bind.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.first == "127",
                  octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
            return bind // haild listens on exactly this loopback address.
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }
}
