import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .frozenGuardBudget) struct VoiceGuardsHeldOriginTests {
    @Test func heldAmbientReleaseKeepsItsOriginWithoutLendingItToOrdinaryInput() async throws {
        let adapter = FinalDeliveryAdapter()
        let clock = ProgressTestClock()
        let policy = Policy(guardPatterns: [VoiceGuardsRoute.rule], deliveriesPerMinute: 2, voiceGuards: .off)
        let route = try await VoiceGuardsRoute.make(adapter: adapter, policy: policy,
            capabilities: [HeldRequests.capability], now: { clock.now })
        _ = try await route.ambient("synthetic benign utterance")
        _ = try await route.ambient("synthetic benign utterance")
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) { try await route.ambient() }
        let entry = try #require(await route.host.heldRequests.entries.values.first)
        #expect(route.log.lines.isEmpty)
        #expect(entry.reasons == [.rateLimited])
        clock.advance(by: .seconds(61))
        // Either ordering leaves ordinary input a rate slot, so its refusal must come from guard escalation.
        async let release = route.session.sendHeld(entry.id, from: entry.connection)
        let ordinary = await route.session.receive(sessionFrame(target: route.target,
            payload: .text(.init(text: VoiceGuardsRoute.words))))
        #expect(ordinary.frames.count == 1)
        #expect(ordinary.frames.contains {
            guard case .control(.error(.notAllowed, let message, _)) = $0.payload else { return false }
            return message == "target requires confirmation at the Mac"
        })
        #expect(await release == .sent)
        let expected = ["synthetic benign utterance", "synthetic benign utterance", VoiceGuardsRoute.words]
        #expect(await adapter.deliveries == expected)
        #expect(route.log.lines.count == 1, "only the ambient release may log guard suppression")
        #expect(try route.log.object()["rules"] as? [String] == [VoiceGuardsRoute.rule.name])
        clock.advance(by: .seconds(61))
        let connection = try #require(await route.listener.connectionID(of: route.peer))
        let local = LocalDispatchRequest(connection: connection, target: route.target,
                                         binding: route.binding, text: VoiceGuardsRoute.words)
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
            try await route.listener.dispatch(local)
        }
        #expect(await adapter.deliveries == expected)
        #expect(route.log.lines.count == 1)
        await route.listener.stop()
    }

    @Test func heldWhileOffCannotSurviveReloadToOn() async throws {
        let adapter = FinalDeliveryAdapter()
        var policy = Policy(guardPatterns: [VoiceGuardsRoute.rule], voiceGuards: .off)
        try policy.allow("final:reply", binding: "synthetic-binding", tier: .confirm)
        let route = try await VoiceGuardsRoute.make(adapter: adapter, policy: policy,
                                                    capabilities: [HeldRequests.capability])
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) { try await route.ambient() }
        let entry = try #require(await route.host.heldRequests.entries.values.first)
        route.setPolicy { $0.voiceGuards = .on }
        _ = await route.host.refreshedPolicy()
        #expect(await route.session.sendHeld(entry.id, from: entry.connection) == .refused(.policyChanged))
        #expect(await adapter.deliveries.isEmpty)
        #expect(route.log.lines.isEmpty)
        await route.listener.stop()
    }
}
