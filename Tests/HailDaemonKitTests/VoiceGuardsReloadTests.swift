import Testing
@testable import HailDaemonKit

@Suite(.serialized, .frozenGuardBudget) struct VoiceGuardsReloadTests {
    @Test func normalReloadRestoresGuardHoldsBeforeTheNextDispatch() async throws {
        let adapter = FinalDeliveryAdapter(), route = try await VoiceGuardsRoute.make(adapter: adapter)
        _ = try await route.ambient()
        #expect(await adapter.deliveries == [VoiceGuardsRoute.words])
        #expect(await route.host.voiceGuardsStatus == .init(value: .off, enforced: true))
        route.setPolicy { $0.voiceGuards = .on }
        // The status read is memory-only; dispatch performs normal policy observation/reload.
        #expect(await route.host.voiceGuardsStatus.value == .off)
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) { try await route.ambient() }
        #expect(await route.host.voiceGuardsStatus == .init(value: .on, enforced: true))
        #expect(await adapter.deliveries == [VoiceGuardsRoute.words])
        #expect(route.log.lines.count == 1)
        await route.listener.stop()
    }
}
