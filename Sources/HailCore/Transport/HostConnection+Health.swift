public import Foundation
public import HailProtocol

extension HostConnection {
    /// Asks a ready host that advertised `host_health` for its doctor summary (#614); the answer arrives as a
    /// `health_report` notice.
    public func requestHealth() async throws {
        try requireReady(capability: HostHealth.capability)
        try await send(.health, generation: generation)
    }
}

/// A host's last health summary (#614) and the connection it came on, so Mac Setup can say when it is from an
/// earlier connection rather than showing an old answer as current.
public struct HostHealthReading: Equatable, Sendable {
    public let report: HostHealth
    public let connectionGeneration: UUID?

    /// True unless `snapshot` is ready on the same connection the report came on.
    public func isStale(for snapshot: HostConnectionSnapshot?) -> Bool {
        guard let snapshot, snapshot.state == .ready else { return true }
        return snapshot.connectionGeneration != connectionGeneration
    }
}

/// How Mac Setup words a host's health summary (#614). The wire carries only check names and outcomes; the plain
/// words live here, so a host never sends free text, and `haild doctor` on the Mac has the detail and the fix.
extension HostHealth {
    /// One line per check, in the host's order.
    public var lines: [(title: String, ok: Bool)] {
        checks.map { (Self.title(for: $0.name, ok: $0.ok), $0.ok) }
    }

    /// The headline: healthy, or how many checks failed, and where to look.
    public var headline: String {
        let failed = checks.count { !$0.ok }
        return failed == 0 ? "haild doctor: all checks pass"
            : "haild doctor: \(failed) check\(failed == 1 ? "" : "s") failed. Run haild doctor on the Mac for the fix."
    }

    /// The version, and the build digest when the host sent one.
    public var buildLine: String {
        build.map { "haild \(version) · build \($0)" } ?? "haild \(version)"
    }

    static func title(for name: String, ok: Bool) -> String {
        switch name {
        case "daemon_running": ok ? "Daemon running" : "Daemon not running"
        case "build_match": ok ? "One installed build" : "Builds differ"
        case "host_id_match": ok ? "Host ID matches" : "Host ID mismatch"
        case "listener_ready": ok ? "Listener ready" : "Listener not ready"
        case "ambient_listening": ok ? "Ambient listening healthy" : "Ambient listening failed"
        case "device_connected": ok ? "Device connected" : "No device connected"
        case "recent_refusals": ok ? "No recent refusals" : "Recent refusals"
        case "audit_history": ok ? "Audit history readable" : "Audit history unreadable"
        default: name
        }
    }
}
