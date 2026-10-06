import Darwin
import Foundation

/// One `haild doctor` check: a stable name, the outcome, what was seen, and a plain-language fix (#247).
public struct HealthCheck: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case ok, fail }

    public var name: String
    public var outcome: Outcome
    public var detail: String
    public var fix: String?

    static func ok(_ name: String, _ detail: String) -> Self { .init(name: name, outcome: .ok, detail: detail) }
    static func fail(_ name: String, _ detail: String, fix: String) -> Self {
        .init(name: name, outcome: .fail, detail: detail, fix: fix)
    }
}

/// The report behind `haild status --json` and `haild doctor`: the CLI's own facts, the daemon's snapshot and
/// the checks that compare them. Each failure seen on 2026-10-03/04 maps to one check (#247).
public struct HealthReport: Codable, Sendable, Equatable {
    public struct CLI: Codable, Sendable, Equatable {
        public var version: String
        public var build: String?
        public var hostID: String?

        public init(version: String, build: String?, hostID: String?) {
            self.version = version
            self.build = build
            self.hostID = hostID
        }
    }

    public var cli: CLI
    public var daemon: DaemonStatus?
    public var checks: [HealthCheck]
    public var healthy: Bool { checks.allSatisfy { $0.outcome == .ok } }

    private enum CodingKeys: String, CodingKey { case cli, daemon, checks, healthy }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cli, forKey: .cli)
        try container.encodeIfPresent(daemon, forKey: .daemon)
        try container.encode(checks, forKey: .checks)
        try container.encode(healthy, forKey: .healthy)
    }

    public init(cli: CLI, daemon: DaemonStatus?, checks: [HealthCheck]) {
        self.cli = cli
        self.daemon = daemon
        self.checks = checks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cli = try container.decode(CLI.self, forKey: .cli)
        daemon = try container.decodeIfPresent(DaemonStatus.self, forKey: .daemon)
        checks = try container.decode([HealthCheck].self, forKey: .checks)
    }

    /// `isRunning` answers whether a pid is a live process; tests inject it.
    public static func evaluate(
        cli: CLI, daemon: DaemonStatus?, isRunning: (Int32) -> Bool = processIsRunning
    ) -> HealthReport {
        let restart = "run scripts/host.sh restart, then haild doctor again"
        guard let daemon else {
            return .init(cli: cli, daemon: nil, checks: [
                .fail("daemon_running", "no daemon status file", fix: "the daemon is not running or predates "
                      + "status reporting; \(restart)")
            ])
        }
        guard isRunning(daemon.pid), daemon.listener.state != "stopped" else {
            return .init(cli: cli, daemon: daemon, checks: [
                .fail("daemon_running", "pid \(daemon.pid) is not running (listener \(daemon.listener.state))",
                      fix: restart)
            ])
        }
        var checks: [HealthCheck] = [.ok("daemon_running", "pid \(daemon.pid)")]
        checks.append(buildCheck(cli: cli.build, daemon: daemon.build))
        if let host = cli.hostID, host == daemon.hostID {
            checks.append(.ok("host_id_match", host))
        } else {
            checks.append(.fail(
                "host_id_match", "daemon \(daemon.hostID), this shell \(cli.hostID ?? "unresolved")",
                fix: "replies from this shell are refused as sourceHostMismatch; set the same HAIL_HOST_ID "
                    + "(hostID in host.json) for the daemon and the target sessions"
            ))
        }
        checks.append(listenerCheck(daemon.listener))
        if let ambient = daemon.ambient { checks.append(ambientCheck(ambient)) }
        checks.append(daemon.connectedSessions > 0
            ? .ok("device_connected", "\(daemon.connectedSessions) connected")
            : .fail("device_connected", "no device connected",
                    fix: "open Hailing Station on the iPhone or iPad and connect to this host"))
        return .init(cli: cli, daemon: daemon, checks: checks)
    }

    private static func buildCheck(cli: String?, daemon: String?) -> HealthCheck {
        guard let cli, let daemon else {
            return .fail("build_match", "build unknown (daemon \(daemon ?? "?"), this haild \(cli ?? "?"))",
                         fix: "redeploy with scripts/host.sh deploy so both run one installed release")
        }
        guard cli == daemon else {
            return .fail("build_match", "daemon \(daemon), this haild \(cli)",
                         fix: "this haild and the daemon are different builds (#115): run the haild on PATH "
                             + "(~/.local/bin/haild), or redeploy with scripts/host.sh deploy")
        }
        return .ok("build_match", cli)
    }

    private static func listenerCheck(_ listener: DaemonStatus.Listener) -> HealthCheck {
        if listener.state == "ready" { return .ok("listener_ready", listener.endpoint ?? "ready") }
        let detail = [listener.state, listener.detail].compactMap { $0 }.joined(separator: ": ")
        let inUse = listener.detail?.contains("Address already in use") == true
        return .fail("listener_ready", detail, fix: inUse
            ? "another listener holds the daemon's port, often Tailscale Serve; give haild its own loopback "
                + "port (docs/host-operations.md, #262)"
            : "check ~/Library/Logs/HailingStation/haild.err.log, then run scripts/host.sh restart")
    }

    /// A clean end (`delivered=…`) or the phone closing its input is healthy idle; a failed run, a refusal or a
    /// shutdown timeout is not (#226).
    private static func ambientCheck(_ ambient: DaemonStatus.Ambient) -> HealthCheck {
        guard ambient.enabled else { return .ok("ambient_listening", "not enabled") }
        let detail = ambient.lastDetail ?? ""
        let logs = "check ~/Library/Logs/HailingStation/haild.err.log for ambient_* events"
        switch ambient.lastEvent {
        case "ambient_ended" where !detail.hasPrefix("delivered="):
            return .fail("ambient_listening", "last run ended: \(detail)", fix: detail.hasPrefix("child ")
                ? "the RightyO child failed (\(detail.dropFirst(6))); reconnect the phone to restart it, and if it "
                    + "repeats, run the RightyO path in host.json by hand and \(logs)"
                : "reconnect the phone to restart ambient listening; if it repeats, \(logs)")
        case "ambient_refused":
            return .fail("ambient_listening", "refused: \(detail)", fix: detail.contains("unsafe")
                ? "the RightyO executable or config failed the ownership and permission checks; fix the paths "
                    + "in host.json, then scripts/host.sh restart"
                : "ambient listening was refused; reconnect the phone, and if it repeats, \(logs)")
        case "ambient_shutdown_timeout":
            return .fail("ambient_listening", "shutdown timed out (\(detail))",
                         fix: "a RightyO child did not stop in time; scripts/host.sh restart, then \(logs)")
        default:
            return .ok("ambient_listening", ambient.running > 0 ? "\(ambient.running) running" : "idle")
        }
    }

    public static func processIsRunning(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
