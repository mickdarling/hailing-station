import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct ReplySegmentsHostSessionTests {
    @Test(arguments: [false, true])
    func unadvertisedReplyYieldUsesExistingAuthorizationRefusal(personal: Bool) async throws {
        let (host, adapter) = try await sessionHost()
        let authorizer: any HostSessionAuthorizing = personal
            ? PersonalTerminalAuthorizer() : ConnectionProbeAuthorizer()
        let session = HostSession(host: host, authorizer: authorizer)
        let hello = await session.receive(helloFrame(capabilities: [ReplySegments.capability]))
        guard case .hello(let info) = try onlyControl(hello) else {
            Issue.record("expected hello")
            return
        }
        #expect(!info.capabilities.contains(ReplySegments.capability))
        let reply = UUID()
        // Seed active reply and selection state to prove that no yield/stop work happens in P1.
        await session.seedReplySegmentsTestState(reply: reply)
        let result = await session.receive(try FrameCoding.encode(sessionFrame(
            payload: .control(.replyYield(reply: reply, segment: 1))
        )))
        #expect(try onlyControl(result) == .error(code: .unauthorized, message: "terminal action is not authorized"))
        #expect(result.disposition == .keepOpen)
        #expect(await session.state == .ready(version: 1))
        #expect(await session.selectedTarget == "tmux:synthetic")
        #expect(await session.repliesInFlight == [reply])
        #expect(await session.stoppedReplies.isEmpty)
        #expect(await session.overheardScope == "off")
        #expect(await adapter.deliveries.isEmpty)
        let pong = await session.receive(sessionFrame(payload: .control(.ping(nonce: "after"))))
        #expect(try onlyControl(pong) == .pong(nonce: "after"))
        // The refusal has fixed text; neither reply identity nor content enters any logging path.
        let encoded = try #require(String(bytes: FrameCoding.encode(result.frames[0]), encoding: .utf8))
        #expect(!encoded.contains(reply.uuidString))
    }
}

private extension HostSession {
    func seedReplySegmentsTestState(reply: UUID) {
        selectedTarget = "tmux:synthetic"
        repliesInFlight = [reply]
    }
}
