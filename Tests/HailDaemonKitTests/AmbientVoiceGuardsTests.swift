import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceGuardsTests {
    /// Fake child -> real consumer -> ambient dispatcher -> HostSession routing -> HailHost -> synthetic adapter.
    @Test(arguments: VoiceGuards.allCases)
    func ambientPipelineHonorsTheEffectiveSetting(_ setting: VoiceGuards) async throws {
        let adapter = FinalDeliveryAdapter()
        let route = try await VoiceGuardsRoute.make(adapter: adapter,
            policy: Policy(guardPatterns: [VoiceGuardsRoute.rule], voiceGuards: setting))
        let script = "/bin/cat > /dev/null\n" + AmbientWiringVoiceMuteTests.fixture(
            saying: "Rightyo, synthetic guarded command", enrolled: true)
        let fake = try FakeRightyo(script)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let events = AmbientEventDetails()
        let router = AmbientRightyoRouter(configuration: .init(
            executable: fake.executable, config: fake.config, target: route.target, binding: route.binding,
            allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 2)
        ), log: { events.record($0) })
        router.attach(route.listener)
        let stream = UUID(), connection = await route.session.connectionID
        let policy = route.host.targetPolicy.snapshot(for: route.target)
        router.ambientAudio(.admittedStart(stream: stream, connection: connection, target: route.target,
                                    selection: await route.session.selectionGeneration, binding: route.binding,
                                    policy: policy))
        try #require(await eventually { router.activeStream == stream })
        router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: Data(count: 3_200)))
        router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(router)
        let deliveries = await adapter.deliveries
        if setting == .off {
            #expect(deliveries.count == 1)
            #expect(deliveries.first?.contains(VoiceGuardsRoute.words) == true)
            #expect(route.log.lines.count == 1)
            #expect(try route.log.object()["rules"] as? [String] == [VoiceGuardsRoute.rule.name])
        } else {
            #expect(deliveries.isEmpty)
            #expect(route.log.lines.isEmpty)
            #expect(events.details("ambient_request_refused").contains { $0.contains("confirmation_required") })
        }
        await router.shutdown()
        await route.listener.stop()
    }

    @Test func staleSelectionStillRefusesBeforePolicy() async throws {
        let adapter = FinalDeliveryAdapter(), route = try await VoiceGuardsRoute.make(adapter: adapter)
        let selection = await route.session.selectionGeneration
        _ = try await route.host.allow("final:other", tier: .open)
        _ = await route.session.receive(sessionFrame(payload: .control(.select(targetID: "final:other"))))
        try #require(await route.session.selectedTarget == "final:other")
        _ = await route.session.receive(sessionFrame(payload: .control(.select(targetID: route.target))))
        try #require(await route.session.selectionGeneration != selection)
        await #expect(throws: LocalDispatchRefusal.selectionChanged) {
            try await route.listener.dispatchAmbient(await route.request(), selection: selection)
        }
        #expect(await adapter.deliveries.isEmpty)
        #expect(route.log.lines.isEmpty)
        await route.listener.stop()
    }
}
