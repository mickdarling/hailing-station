#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #405 over the owner-only socket: the `ambient` kind reloads and reports, audited, with no content.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringLocalSocketTests {
    @Test func theSocketReloadsAndReportsWithoutContent() async throws {
        let fake = try FakeRightyo("exec /bin/sleep 60")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.2, termGrace: 0.2))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-amb-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let auditDirectory = scratch.appendingPathComponent("audit")
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: env.listener,
                                              audit: AuditLog(directory: auditDirectory))
        try await endpoint.start()
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let idle = try await submit(Data(#"{"kind":"ambient","action":"reload"}"#.utf8), socket: socket.path)
        #expect(idle.ambient?.outcome == .idle)
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        try await pair.barrier()
        let reloaded = try await submit(Data(#"{"kind":"ambient","action":"reload"}"#.utf8), socket: socket.path)
        #expect(reloaded.ambient?.outcome == .reloaded)
        #expect(reloaded.ambient?.active == true)
        let status = try await submit(Data(#"{"kind":"ambient","action":"status"}"#.utf8), socket: socket.path)
        #expect(status.ambient?.outcome == .status)
        #expect(status.ambient?.target == RecipientTestRig.target)
        #expect(status.ambient?.since != nil)
        let refused = try await submit(Data(#"{"kind":"ambient","action":"start"}"#.utf8), socket: socket.path)
        #expect(refused == LocalReplyResponse(delivered: 0, error: LocalReplyRefusal.decodeFailure.message,
                                              code: .decodeFailure))
        try await pair.barrier()
        #expect(await env.gate.activeStream == stream)
        let history = try AuditHistory(directory: auditDirectory).today()
        #expect(history.filter { $0.contains("local-ambient") }.count == 3)
        await endpoint.stop()
        await env.listener.stop(reason: "synthetic test complete")
    }
}

/// #405: the local `ambient` request shape is exact, and a host without ambient wiring touches nothing.
@Suite struct LocalAmbientRequestTests {
    private func decode(_ json: String) -> LocalAmbientRequest? {
        try? JSONDecoder().decode(LocalAmbientRequest.self, from: Data(json.utf8))
    }

    @Test func onlyTheExactShapeDecodes() throws {
        #expect(decode(#"{"kind":"ambient","action":"reload"}"#) == LocalAmbientRequest(action: .reload))
        #expect(decode(#"{"action":"status","kind":"ambient"}"#) == LocalAmbientRequest(action: .status))
        #expect(decode(#"{"kind":"ambient","action":"on"}"#) == nil)
        #expect(decode(#"{"kind":"ambient","action":"off"}"#) == nil)
        #expect(decode(#"{"kind":"ambient"}"#) == nil)
        #expect(decode(#"{"kind":"dispatch","action":"reload"}"#) == nil)
        #expect(decode(#"{"kind":"ambient","action":"reload","connection":"x"}"#) == nil)
        let encoded = try JSONEncoder().encode(LocalAmbientRequest(action: .reload))
        let decoded = try JSONDecoder().decode(LocalAmbientRequest.self, from: encoded)
        #expect(decoded == LocalAmbientRequest(action: .reload))
    }

    @Test func replyAndDispatchResponsesCarryNoAmbientKey() throws {
        let reply = try #require(String(bytes: try JSONEncoder().encode(LocalReplyResponse(delivered: 1)),
                                        encoding: .utf8))
        #expect(!reply.contains("ambient"))
        let answer = LocalReplyResponse.ambient(LocalAmbientReport(outcome: .busy, liveChildren: 2))
        #expect(try JSONDecoder().decode(LocalReplyResponse.self, from: JSONEncoder().encode(answer)) == answer)
    }

    @Test func aListenerWithoutAmbientAndAPlainPublisherAreNotEnabled() async throws {
        let rig = try await RecipientTestRig.make()
        let (listener, _) = try dispatchListener(rig: rig)
        _ = try await listener.start()
        #expect(await listener.ambient(LocalAmbientRequest(action: .reload)).outcome == .notEnabled)
        #expect(await listener.ambient(LocalAmbientRequest(action: .status)).outcome == .notEnabled)
        await listener.stop(reason: "synthetic test complete")
        #expect(await PlainPublisher().ambient(LocalAmbientRequest(action: .reload)).outcome == .notEnabled)
    }
}

private struct PlainPublisher: HostReplyPublishing {
    func publish(_ frame: Frame) async throws -> Int { 0 }
}
#endif
