import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct HeldRequestLegacyTests {
    @Test func listenerSendKeepsTheMintedReplyReferenceAndExactPrompt() async throws {
        var policy = Policy(guardPatterns: [.init(name: "private rule", regex: "HELD_TOKEN")])
        try policy.allow("tmux:demo", binding: "original", tier: .open)
        let (host, adapter) = try await sessionHost(targets: [.init(name: "demo", binding: "original")], policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:demo"))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                             authorizer: PersonalTerminalAuthorizer())
        let peer = try #require(await listener.installFallbackSyntheticPeers([session]).first)
        let connection = await session.connectionID
        let reference = UUID()
        let text = "HELD_TOKEN prepared reply \(reference.uuidString)"
        let result = try await listener.dispatchAmbientResult(.init(connection: connection, target: "tmux:demo",
            binding: "original", text: text), reference: reference, selection: session.selectionGeneration)
        guard case .held(let notice) = result else { throw HeldTestError.expectedHold }
        let entry = try #require(await host.heldRequests.entries[notice.held])
        #expect(await listener.sendHeld(entry.id, from: connection) == .sent)
        #expect(await adapter.deliveries.map(\.text) == [text])
        #expect(await session.replyRequests[reference]?.committed == true)
        #expect(await listener.sendHeld(entry.id, from: connection) == .sent)
        #expect(await listener.discardHeld(entry.id, from: connection) == .sent)
        #expect(await listener.heldStatus(entry.id, from: connection) == .sent)
        await peer.finish(reason: "synthetic close")
        #expect(await listener.sendHeld(UUID(), from: connection) == .refused(.connectionLost))
        await listener.stop(reason: "synthetic complete")
    }

    @Test func wireDecisionsCannotSendOrDiscardHeldContent() async throws {
        let rig = try await HeldTestRig.make()
        let entry = try await rig.hold()
        #expect(!HostSession.capabilities.contains(HeldRequests.capability))
        #expect(!PersonalTerminalAuthorizer().capabilities.contains(HeldRequests.capability))
        for action in [HeldRequestAction.send, .discard] {
            let frame = sessionFrame(payload: .control(.heldDecision(.init(held: entry.id, action: action))))
            let result = await rig.session.receive(try FrameCoding.encode(frame))
            #expect(!result.frames.isEmpty)
            #expect(await rig.host.heldRequests.status(entry.id, from: entry.connection) == .pending)
            #expect(await rig.adapter.contexts.isEmpty)
        }
    }

    @Test func expiredTimeoutNoticeWithFreshCleanEvaluationStillDoesNotAutoDeliver() async throws {
        let rig = try await HeldTestRig.make()
        let frozen = ContinuousClock.now
        let budget = GuardBudgetClock(now: { frozen }, cpuNow: { nil })
        let entry = try await GuardBudgetClock.$current.withValue(budget) { try await rig.hold("benign") }
        rig.clock.advance(120_000)
        guard case .held(let notice) = await rig.send(entry.id) else { throw HeldTestError.expectedHold }
        #expect(notice.held == entry.id)
        #expect(await rig.adapter.contexts.isEmpty)
        #expect(await rig.send(entry.id) == .sent)
    }
}
