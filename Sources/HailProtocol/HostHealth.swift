import Foundation

/// A host's read-only health summary (#614): its `haild doctor` checks and build, so a broken host is visible from a
/// device's Mac Setup. A device asks with `health`, only of a host that advertised `capability`; the host answers
/// with `health_report`. Closed and bounded: each check is a known name and whether it passed, never the doctor's
/// free-text detail or fix (which can name paths, ports and identities), and the build is a version and a short
/// digest. It grants no authority.
public struct HostHealth: Codable, Sendable, Equatable {
    public static let capability = "host_health"
    /// The `haild doctor` check names (#247) a report may carry.
    public static let checkNames = [
        "daemon_running", "build_match", "host_id_match", "listener_ready", "ambient_listening", "device_connected",
        "recent_refusals", "audit_history"
    ]
    public static let maxChecks = 16

    public struct Check: Codable, Sendable, Equatable {
        public var name: String
        public var ok: Bool

        public init(name: String, ok: Bool) {
            self.name = name
            self.ok = ok
        }

        private enum CodingKeys: String, CodingKey { case name, ok }

        public init(from decoder: any Decoder) throws {
            let keys = try decoder.container(keyedBy: DiagnosticCodingKey.self).allKeys.map(\.stringValue)
            guard keys.allSatisfy({ ["name", "ok"].contains($0) }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "unknown health check key"))
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode(String.self, forKey: .name)
            guard let name = HostHealth.checkName(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "unknown health check name"))
            }
            self.name = name
            ok = try container.decode(Bool.self, forKey: .ok)
        }

        public func encode(to encoder: any Encoder) throws {
            guard HostHealth.checkName(name) != nil else {
                throw EncodingError.invalidValue(name, .init(codingPath: encoder.codingPath,
                                                             debugDescription: "unknown health check name"))
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(ok, forKey: .ok)
        }
    }

    /// The host's release version, as `haild` reports it (`0.1.0`).
    public var version: String
    /// The first 16 hex digits of the running executable's SHA-256, when the host could read it.
    public var build: String?
    public var checks: [Check]
    public var healthy: Bool { checks.allSatisfy(\.ok) }

    public init(version: String, build: String?, checks: [Check]) {
        self.version = version
        self.build = build
        self.checks = checks
    }

    private enum CodingKeys: String, CodingKey { case version, build, checks }

    public init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: DiagnosticCodingKey.self).allKeys.map(\.stringValue)
        guard keys.allSatisfy({ ["version", "build", "checks"].contains($0) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown health_report key"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        build = try container.decodeIfPresent(String.self, forKey: .build)
        checks = try container.decode([Check].self, forKey: .checks)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "invalid health_report"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                                                         debugDescription: "invalid health_report"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(build, forKey: .build)
        try container.encode(checks, forKey: .checks)
    }

    /// A version of 1–32 of `0-9 A-Z a-z . + -`; a build of exactly 16 lowercase hex digits; 1–16 checks, each name
    /// at most once.
    var isValid: Bool {
        let versionScalars = CharacterSet(charactersIn: "0123456789.+-")
            .union(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"))
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return (1...32).contains(version.unicodeScalars.count)
            && version.unicodeScalars.allSatisfy(versionScalars.contains)
            && build.map { $0.unicodeScalars.count == 16 && $0.unicodeScalars.allSatisfy(hex.contains) } ?? true
            && (1...Self.maxChecks).contains(checks.count)
            && Set(checks.map(\.name)).count == checks.count
    }

    /// `value` when it is exactly one of `checkNames`, else nil.
    public static func checkName(_ value: String?) -> String? {
        value.flatMap { value in checkNames.first { DiagnosticLimits.sameBytes($0, value) } }
    }
}
