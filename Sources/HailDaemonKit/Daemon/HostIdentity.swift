public import Foundation
import SystemConfiguration

public enum HostIdentityError: Error, Equatable, Sendable {
    /// `HAIL_HOST_ID` is set but is not a usable host identifier.
    case invalidOverride(String)
}

/// The one host identity shared by the daemon and `haild reply` (#246). `ProcessInfo.hostName` comes from
/// network name resolution and changes with the network, so a daemon and a later CLI call could disagree
/// and every reply was refused as `sourceHostMismatch` (#84, #230). Resolution order:
/// 1. `HAIL_HOST_ID`, for an operator-pinned identity;
/// 2. the Mac's LocalHostName (the user-set Bonjour name, stable across networks) as `<name>.local`;
/// 3. `ProcessInfo.hostName`, only when no LocalHostName is available.
/// Every result is canonical: lowercase, no trailing dot.
public enum HostIdentity {
    public static let environmentKey = "HAIL_HOST_ID"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        localHostName: () -> String? = systemLocalHostName,
        networkHostName: () -> String = { ProcessInfo.processInfo.hostName }
    ) throws -> String {
        if let override = environment[environmentKey] {
            guard let identity = canonical(override) else { throw HostIdentityError.invalidOverride(override) }
            return identity
        }
        if let name = localHostName(), let identity = canonical(name + ".local") { return identity }
        return canonical(networkHostName()) ?? "localhost"
    }

    /// Lowercase, trailing dot removed; nil unless the result is a DNS-style name of at most 253 bytes.
    static func canonical(_ name: String) -> String? {
        var value = name.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !value.isEmpty, value.utf8.count <= 253, value.allSatisfy(allowed.contains),
              !value.hasPrefix("."), !value.contains("..") else { return nil }
        return value
    }

    public static func systemLocalHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }
}
