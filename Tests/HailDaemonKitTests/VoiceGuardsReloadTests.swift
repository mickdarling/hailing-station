import Foundation
import HailProtocol
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

    @Test func explicitReloadToOffAppliesBeforeAmbientDispatch() async throws {
        let adapter = FinalDeliveryAdapter()
        let route = try await VoiceGuardsRoute.make(adapter: adapter,
            policy: Policy(guardPatterns: [VoiceGuardsRoute.rule], voiceGuards: .on))
        route.setPolicy { $0.voiceGuards = .off }
        _ = await route.host.refreshedPolicy()
        #expect(await route.host.voiceGuardsStatus.value == .off)
        _ = try await route.ambient()
        #expect(await adapter.deliveries == [VoiceGuardsRoute.words])
        #expect(route.log.lines.count == 1)
        await route.listener.stop()
    }

    @Test func unusablePolicyRefusesAmbientDispatchWithoutSkipLogging() async throws {
        let adapter = FinalDeliveryAdapter(), route = try await VoiceGuardsRoute.make(adapter: adapter)
        route.store.setLoadError(PolicyFormatError.invalidVoiceGuards("malformed"))
        _ = await route.host.refreshedPolicy()
        #expect(await route.host.voiceGuardsStatus.value == .unusable)
        await #expect(throws: (any Error).self) { try await route.ambient() }
        #expect(await adapter.deliveries.isEmpty)
        #expect(route.log.lines.isEmpty)
        await route.listener.stop()
    }

    @Test func malformedSettingOnDiskRefusesRealAmbientDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-voice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PolicyFile(directory: directory)
        var policy = Policy(guardPatterns: [VoiceGuardsRoute.rule], voiceGuards: .off)
        try policy.allow("final:reply", binding: "synthetic-binding", tier: .open)
        try file.save(policy)
        let adapter = FinalDeliveryAdapter(), registry = Registry(), log = VoiceGuardsLog()
        try await registry.register(adapter)
        let host = try HailHost(registry: registry, store: file, voiceGuardLog: log.record)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "final:reply"))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                             authorizer: PersonalTerminalAuthorizer())
        await listener.installFallbackSyntheticPeers([session])
        try Data(#"{"version":1,"voiceGuards":null}"#.utf8).write(to: file.path)
        let dispatcher = AmbientListenerDispatcher(listener: listener, audit: nil,
            selection: await session.selectionGeneration, streamTarget: "final:reply")
        await #expect(throws: (any Error).self) {
            try await dispatcher.dispatch(.init(connection: session.connectionID, target: "final:reply",
                binding: "synthetic-binding", text: VoiceGuardsRoute.words), routed: false)
        }
        // Target-policy observation can refuse first; the host status read itself never reloads.
        _ = await host.refreshedPolicy()
        #expect(await host.voiceGuardsStatus.value == .unusable)
        #expect(await adapter.deliveries.isEmpty)
        #expect(log.lines.isEmpty)
        await listener.stop()
    }
}
