#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #609: `haild notify` reaches the listener's session update policy. Off by default; the speaking session must be a
/// live registry target; quiet, media mode and the per-session budget apply. Synthetic only; nothing is spoken here.
@Suite struct LocalSessionUpdateTests {
    /// A listening device and its media mode, as the ambient router would report them.
    final class ListeningWiring: AmbientListenerWiring {
        let listening = Mutex<UUID?>(nil)
        let media = Mutex(false)
        func attach(_ listener: WebSocketListener) {}
        func stop(connection: UUID) {}
        func shutdown() async {}
        func isLatest(stream: UUID, connection: UUID) -> Bool { false }
        func activeConnection() -> UUID? { listening.withLock { $0 } }
        func mediaMode(connection: UUID) -> Bool { media.withLock { $0 } }
    }

    private func request(
        _ action: LocalSessionUpdateRequest.Action, target: String = RecipientTestRig.target,
        priority: SessionUpdatePriority? = nil, text: String = "The deck is built"
    ) -> LocalSessionUpdateRequest {
        LocalSessionUpdateRequest(action: action, target: target, priority: priority, text: text)
    }

    private func withListener(
        enabled: Bool = true, _ body: (WebSocketListener, ListeningWiring) async throws -> Void
    ) async throws {
        let rig = try await RecipientTestRig.make()
        let wiring = ListeningWiring()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.host,
                                             authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test",
                                             ambient: wiring)
        if enabled { await listener.enableSessionUpdates() }
        do { try await body(listener, wiring) } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    @Test func offByDefault() async throws {
        try await withListener(enabled: false) { listener, _ in
            #expect(await listener.sessionUpdate(request(.submit)).outcome == .notEnabled)
            #expect(await listener.sessionUpdate(.init(action: .status)).outcome == .notEnabled)
        }
    }

    @Test func theSessionMustBeALiveRegistryTarget() async throws {
        try await withListener { listener, _ in
            let refused = await listener.sessionUpdate(request(.submit, target: "Some Other Session"))
            #expect(refused.outcome == .refused && refused.reason == "unknown_target")
            #expect(await listener.sessionUpdate(.init(action: .status)).held == 0)
        }
    }

    @Test func everythingIsHeldAndActionIsPushedOnlyWithADeviceAndNoQuiet() async throws {
        try await withListener { listener, wiring in
            let info = await listener.sessionUpdate(request(.submit))
            #expect(info.outcome == .held && !info.push)
            let idle = await listener.sessionUpdate(request(.submit, priority: .action))
            #expect(idle.outcome == .held && !idle.push, "no listening or last active device: nothing to push")
            wiring.listening.withLock { $0 = UUID() }
            let listening = await listener.sessionUpdate(request(.submit, priority: .action))
            #expect(listening.outcome == .held && listening.push,
                    "never handed to the reply path, whose routing may pick another device (#605, #551)")
            wiring.media.withLock { $0 = true }
            let media = await listener.sessionUpdate(request(.submit, priority: .action))
            #expect(media.outcome == .held && media.push, "media mode holds and pushes")
            #expect(await listener.sessionUpdate(.init(action: .quietOn)).quiet)
            let quiet = await listener.sessionUpdate(request(.submit, priority: .action))
            #expect(quiet.outcome == .held && !quiet.push && quiet.held == 5)
        }
    }

    @Test func everyUpdateSpendsTheSessionsBudget() async throws {
        try await withListener { listener, wiring in
            wiring.listening.withLock { $0 = UUID() }
            for _ in 0..<SessionUpdatePolicy().perSessionLimit {
                #expect(await listener.sessionUpdate(request(.submit, priority: .action)).outcome == .held)
            }
            for priority in [SessionUpdatePriority.info, .action] {
                let limited = await listener.sessionUpdate(request(.submit, priority: priority))
                #expect(limited.outcome == .refused && limited.reason == "rate_limited")
                #expect((limited.retryAfter ?? 0) > 3_500)
                #expect(limited.held == SessionUpdatePolicy().perSessionLimit, "a refusal holds nothing")
            }
        }
    }

    @Test func aPlainPublisherIsNotEnabled() async {
        #expect(await PlainUpdatePublisher().sessionUpdate(request(.submit)).outcome == .notEnabled)
    }
}

/// #609: the local `update` request shape is exact.
@Suite struct LocalSessionUpdateRequestTests {
    private func decode(_ json: String) -> LocalSessionUpdateRequest? {
        try? JSONDecoder().decode(LocalSessionUpdateRequest.self, from: Data(json.utf8))
    }

    @Test func onlyTheKeysTheActionUsesDecode() throws {
        #expect(decode(#"{"kind":"update","action":"submit","target":"tmux:a","text":"Done"}"#)
                == LocalSessionUpdateRequest(action: .submit, target: "tmux:a", text: "Done"))
        #expect(decode(#"{"kind":"update","action":"submit","target":"tmux:a","priority":"action","#
                       + #""text":"Done","card":"PR #1"}"#)?.card == "PR #1")
        for removed in ["hold", "announce", "quiet_off"] {
            #expect(decode(#"{"kind":"update","action":"\#(removed)","target":"tmux:a","text":"x"}"#) == nil)
            #expect(decode(#"{"kind":"update","action":"\#(removed)"}"#) == nil,
                     "no hold or announce until haild delivers itself; a session cannot turn quiet off")
        }
        #expect(decode(#"{"kind":"update","action":"quiet_on"}"#) == LocalSessionUpdateRequest(action: .quietOn))
        #expect(decode(#"{"kind":"update","action":"status"}"#) == LocalSessionUpdateRequest(action: .status))
        #expect(decode(#"{"kind":"update","action":"submit","text":"Done"}"#) == nil, "no target")
        #expect(decode(#"{"kind":"update","action":"submit","target":"tmux:a"}"#) == nil, "no text")
        #expect(decode(#"{"kind":"update","action":"status","target":"tmux:a"}"#) == nil)
        #expect(decode(#"{"kind":"update","action":"submit","target":"tmux:a","text":"x","session":"Jarvis"}"#)
                == nil, "the session name is never caller-supplied")
        #expect(decode(#"{"kind":"update","action":"submit","target":"tmux:a","text":"x","priority":"urgent"}"#)
                == nil)
        #expect(decode(#"{"kind":"ambient","action":"status"}"#) == nil)
        let sent = LocalSessionUpdateRequest(action: .submit, target: "tmux:a", priority: .action, text: "Back")
        #expect(try JSONDecoder().decode(LocalSessionUpdateRequest.self, from: JSONEncoder().encode(sent)) == sent)
    }

    @Test func otherResponsesCarryNoUpdateKey() throws {
        let reply = try #require(String(bytes: try JSONEncoder().encode(LocalReplyResponse(delivered: 1)),
                                        encoding: .utf8))
        #expect(!reply.contains("update"))
        var report = LocalSessionUpdateReport(outcome: .refused, reason: "rate_limited")
        report.retryAfter = 30
        let answer = LocalReplyResponse.update(report)
        #expect(try JSONDecoder().decode(LocalReplyResponse.self, from: JSONEncoder().encode(answer)) == answer)
    }

    @Test func theRunFlagIsOptInAndPersonalTerminalOnly() throws {
        let base = ["--bind", "127.0.0.1", "--port", "4100"]
        #expect(try ConnectionProbeDaemon.options(base + ["--personal-terminal"]).sessionUpdates == false)
        #expect(try ConnectionProbeDaemon.options(base + ["--personal-terminal", "--session-updates"]).sessionUpdates)
        #expect(throws: WebSocketListenerError.self) {
            try ConnectionProbeDaemon.options(base + ["--connection-probe", "--session-updates"])
        }
    }
}

/// #609 over the owner-only socket: the `update` kind is answered and audited, never with the update's words.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LocalSessionUpdateSocketTests {
    @Test func theSocketAnswersAndAuditsWithoutContent() async throws {
        let rig = try await RecipientTestRig.make()
        let (listener, _) = try dispatchListener(rig: rig)
        await listener.enableSessionUpdates()
        _ = try await listener.start()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-upd-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let auditDirectory = scratch.appendingPathComponent("audit")
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: listener,
                                              audit: AuditLog(directory: auditDirectory))
        try await endpoint.start()
        let line = #"{"kind":"update","action":"submit","target":"\#(RecipientTestRig.target)","#
            + #""text":"Synthetic secret words"}"#
        let held = try await submit(Data(line.utf8), socket: socket.path)
        #expect(held.update?.outcome == .held && held.update?.held == 1)
        let status = try await submit(Data(#"{"kind":"update","action":"status"}"#.utf8), socket: socket.path)
        #expect(status.update?.outcome == .status)
        let refused = try await submit(Data(#"{"kind":"update","action":"shout"}"#.utf8), socket: socket.path)
        #expect(refused.code == .decodeFailure && refused.update == nil)
        let unknown = #"{"kind":"update","action":"submit","target":"Synthetic Unlisted Name","text":"x"}"#
        #expect(try await submit(Data(unknown.utf8), socket: socket.path).update?.reason == "unknown_target")
        let history = try AuditHistory(directory: auditDirectory).today()
        #expect(history.filter { $0.contains("local-update") }.count == 3)
        #expect(!history.contains { $0.contains("Synthetic secret words") })
        #expect(!history.contains { $0.contains("Synthetic Unlisted Name") }, "the action token, never caller text")
        await endpoint.stop()
        await listener.stop(reason: "synthetic test complete")
    }
}

private struct PlainUpdatePublisher: HostReplyPublishing {
    func publish(_ frame: Frame) async throws -> Int { 0 }
}
#endif
