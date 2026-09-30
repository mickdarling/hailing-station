import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Complete synthetic utility ingress and origin admission, with no renderer, network or physical device.
@Suite struct DiagnosticBridgeRecipientTests {
    @Test(arguments: [false, true])
    func utilityRetainsOriginAcrossTwoClientsAndInterleavedCompletion(reverseOrder: Bool) async throws {
        let publisher = DiagnosticSyntheticPublisher()
        let bridge = try diagnosticBridge(publisher)
        let registry = Registry()
        try await registry.register(bridge)
        var policy = Policy()
        try policy.allow(DiagnosticReplyBridgeAdapter.targetID, binding: diagnosticUtilityBinding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let first = await utilitySession(host)
        let second = await utilitySession(host)
        let sessions = reverseOrder ? [second, first] : [first, second]
        for session in sessions {
            let result = await session.receive(sessionFrame(
                target: DiagnosticReplyBridgeAdapter.targetID, payload: .text(TextPayload(text: "same synthetic input"))
            ))
            #expect(result.frames.isEmpty)
        }
        await publisher.waitForCount(2)
        let replies = await publisher.replies.sorted { $0.sequence < $1.sequence }
        #expect(replies.count == 2)
        #expect(replies[0].requestID != replies[1].requestID)
        for index in [1, 0] {
            let frame = utilityReplyFrame(replies[index])
            #expect(!(await sessions[1 - index].acceptsHostReply(frame)))
            #expect(await sessions[index].acceptsHostReply(frame))
            #expect(!(await sessions[index].acceptsHostReply(frame)))
            await publisher.complete(replies[index].requestID)
        }
        try await diagnosticWait { await bridge.diagnostics().completed == 2 }
        await bridge.stop()
    }
}

private func utilitySession(_ host: HailHost) async -> HostSession {
    let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
    _ = await session.receive(helloFrame())
    _ = await session.receive(sessionFrame(payload: .control(.select(
        targetID: DiagnosticReplyBridgeAdapter.targetID
    ))))
    return session
}

private func utilityReplyFrame(_ reply: DiagnosticBridgeReply) -> Frame {
    let descriptor = ReplyDescriptor(id: UUID(), hostID: reply.hostID, targetID: reply.targetID,
                                     requestID: reply.requestID)
    return Frame(timestamp: 1, target: reply.targetID, source: reply.hostID,
                 payload: .text(TextPayload(text: reply.text, reply: descriptor)))
}
