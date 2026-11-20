#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ConfiguredAmbientReallowTests {
    @Test(arguments: [false, true])
    func freshStreamUsesTheOwnerApprovedReplacement(reload: Bool) async throws {
        let rig = try await ConfiguredAmbientRig.make()
        do {
            #expect(await rig.segment(UUID(), final: true).frames.isEmpty)
            await boundedSettle(rig.router)
            try #require(await rig.base.adapter.deliveries.map(\.binding) == ["s"])
            try await rig.rebind(allow: true)
            let stream = UUID()
            if reload { try rewriteFake(rig.fake, "/bin/cat > original.bin") }
            #expect(await rig.segment(stream, final: !reload).frames.isEmpty)
            let scope = try rig.scope()
            #expect(scope.binding == "replacement")
            if reload {
                try #require(await eventually { fakeFileSize(rig.fake, "original.bin") == 3_200 })
                let generation = try #require(scope.policyGeneration)
                #expect(rig.router.state.withLock {
                    $0.active?.policyGeneration?.isSameGeneration(as: generation) == true
                })
                try rewriteFake(rig.fake, ambientEchoAtEOF)
                #expect(await rig.router.reload() == .reloaded)
                #expect(rig.router.state.withLock {
                    $0.active?.binding == "replacement"
                        && $0.active?.policyGeneration?.isSameGeneration(as: generation) == true
                })
                #expect(await rig.segment(stream, 1, final: true).frames.isEmpty)
            }
            await boundedSettle(rig.router)
            #expect(await rig.base.adapter.deliveries.map(\.binding) == ["s", "replacement"])
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test func configuredStreamsKeepRoutedBindingResolution() async throws {
        let behavior = "/bin/cat > /dev/null\n"
            + AmbientWiringVoiceMuteTests.fixture(saying: "Deck, check the plan.", enrolled: true)
        let rig = try await ConfiguredAmbientRig.make(behavior: behavior, fixture: "enrolled-formed-request.jsonl",
                                                      routes: VoiceRouteRig.routes())
        #expect(await rig.segment(UUID(), final: true).frames.isEmpty)
        await boundedSettle(rig.router)
        let deliveries = await rig.base.adapter.deliveries
        #expect(deliveries.map(\.target) == ["deck"])
        #expect(deliveries.map(\.binding) == ["d"])
        await rig.cleanUp()
    }
}
#endif
