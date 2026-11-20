import Foundation
import Testing
@testable import HailDaemonKit

/// The host.json bridge emits these startup arguments. Synthetic peers and scratch sockets; no live config or child.
@Suite struct SessionUpdateLimitConfigurationTests {
    let base = ["--bind", "127.0.0.1", "--port", "9000", "--personal-terminal", "--session-updates"]

    func arguments(_ limit: String, _ seconds: String) -> [String] {
        base + ["--session-update-per-session-limit", limit, "--session-update-window-seconds", seconds]
    }

    @Test func absentCapIsUnlimitedAndValidCapReachesListener() async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host)
        try await ConnectionProbeDaemon.configureProactive(listener, options: ConnectionProbeDaemon.options(base))
        #expect(await listener.sessionUpdates.policy == SessionUpdatePolicy(enabled: true))
        for (limit, seconds) in [(1, 1), (6, 3_600), (10_000, 86_400)] {
            let options = try ConnectionProbeDaemon.options(arguments(String(limit), String(seconds)))
            try await ConnectionProbeDaemon.configureProactive(listener, options: options)
            #expect(await listener.sessionUpdates.policy
                    == SessionUpdatePolicy(enabled: true, perSessionLimit: limit, window: .seconds(seconds)))
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func invalidCapRefusesStartupWithSettingNamesAndBounds() {
        for (limit, seconds) in [("0", "60"), ("-1", "60"), ("1.5", "60"), ("10001", "60"),
                                 ("6", "0"), ("6", "-1"), ("6", "1.5"), ("6", "86401"),
                                 ("18446744073709551616", "60"), ("true", "60"), ("", "60")] {
            #expect(throws: ConnectionProbeDaemon.SessionUpdateLimitError.self) {
                try ConnectionProbeDaemon.options(arguments(limit, seconds))
            }
        }
        let message = ConnectionProbeDaemon.SessionUpdateLimitError().description
        #expect(message.contains("sessionUpdatePerSessionLimit (1...10000)"))
        #expect(message.contains("sessionUpdateWindowSeconds (1...86400)"))
    }

    @Test func incompleteDuplicateOrDisabledCapsRefuseStartup() {
        let disabled = Array(base.dropLast())
            + ["--session-update-per-session-limit", "6", "--session-update-window-seconds", "60"]
        let invalid: [[String]] = [
            base + ["--session-update-per-session-limit", "6"],
            base + ["--session-update-window-seconds", "60"],
            base + ["--session-update-per-session-limit"],
            arguments("6", "60") + ["--session-update-per-session-limit", "6"],
            arguments("6", "60") + ["--session-update-window-seconds", "60"],
            disabled
        ]
        for values in invalid {
            #expect(throws: ConnectionProbeDaemon.SessionUpdateLimitError.self) {
                try ConnectionProbeDaemon.options(values)
            }
        }
    }

    @Test func configuredCapKeepsQueueRefusalsAndSocketGuard() async throws {
        let options = try ConnectionProbeDaemon.options(arguments("2", "3600"))
        try await withConfiguredCapSocket(options: options) { rig, socket in
            let started = ContinuousClock.now
            let data = try JSONEncoder().encode(LocalSessionUpdateRequest(action: .submit,
                target: RecipientTestRig.target, text: "Synthetic card"))
            for index in 0..<60 {
                let response = try await submit(data, socket: socket)
                let report = try #require(response.update)
                #expect(report.outcome == (index < 2 ? .delivered : .refused))
                if index >= 2 {
                    #expect(report.reason == "rate_limited")
                    #expect((report.retryAfter ?? 0) > 3_500)
                }
            }
            let response = try await submit(data, socket: socket)
            let report = try #require(response.update)
            #expect(report.outcome == .refused && report.reason == "runaway_guard")
            #expect((report.retryAfter ?? 0) > 0 && (report.retryAfter ?? 61) <= 60)
            #expect(rig.sends == 2)
            #expect(await rig.listener.sessionUpdates.sent[RecipientTestRig.target]?.count == 2)
            #expect(ContinuousClock.now - started < .seconds(60))
        }
    }
}

private func withConfiguredCapSocket(
    options: ConnectionProbeDaemon.Options, _ body: (SilentUpdateRig, String) async throws -> Void
) async throws {
    let rig = try await SilentUpdateRig.make()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hs-cg-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appendingPathComponent("c/replies.sock")
    let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: rig.listener,
        audit: AuditLog(directory: directory.appendingPathComponent("audit")))
    do {
        try await ConnectionProbeDaemon.configureProactive(rig.listener, options: options)
        try await endpoint.start()
        try await body(rig, socket.path)
    } catch {
        await endpoint.stop()
        await rig.listener.stop()
        throw error
    }
    await endpoint.stop()
    await rig.listener.stop()
}
