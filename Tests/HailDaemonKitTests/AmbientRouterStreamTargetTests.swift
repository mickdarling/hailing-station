#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #327 PR 2a: inject STARTED at the router seam; the shipping gate still pins its one target.
/// Fake children and synthetic sessions only, with no capture, installed daemon or physical playback.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientRouterStreamTargetTests {
    @Test(arguments: [false, true], [false, true])
    func startedTargetDrivesTheConsumerDispatcherAndReload(routed: Bool, reload: Bool) async throws {
        let words = routed ? "Hailing Scratch, check the plan." : "Rightyo, check the plan."
        let behavior = "/bin/cat > audio.bin\n" + AmbientWiringVoiceMuteTests.fixture(saying: words, enrolled: true)
        let fake = try FakeRightyo(reload ? "/bin/cat > original.bin" : behavior)
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let rig = try await VoiceRouteRig.make()
        let env = try await setup(fake, rig: rig)
        let (session, router) = (env.session, env.router)
        let stream = UUID(), connection = await session.connectionID
        do {
            router.ambientAudio(.started(stream: stream, connection: connection, target: VoiceRouteRig.deck,
                                         selection: await session.selectionGeneration, binding: "d"))
            try #require(await eventually { router.activeStream == stream })
            #expect(router.status().target == VoiceRouteRig.deck)
            #expect(router.state.withLock { $0.active?.target == VoiceRouteRig.deck && $0.active?.binding == "d" })
            router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: Data(count: 3_200)))
            if reload {
                try #require(await eventually { fakeFileSize(fake, "original.bin") == 3_200 })
                try rewriteFake(fake, behavior)
                #expect(await router.reload() == .reloaded)
                #expect(router.state.withLock { $0.active?.target == VoiceRouteRig.deck && $0.active?.binding == "d" }
                        && router.status().target == VoiceRouteRig.deck)
                router.ambientAudio(.segment(stream: stream, sequence: 1, bytes: Data(count: 3_200)))
            }
            router.ambientAudio(.ended(stream: stream, reason: .final))
            await boundedSettle(router)
            let deliveries = await rig.adapter.deliveries
            try #require(deliveries.count == 1)
            #expect(deliveries[0].target == (routed ? "scratch" : "deck")
                    && deliveries[0].binding == (routed ? "s" : "d"))
            // Routing to scratch must still retain STARTED's deck as the dispatcher's source.
            #expect(blockReference(in: deliveries[0].text) != nil)
            #expect(router.streamTarget(on: connection) == VoiceRouteRig.deck)
            #expect(router.status().target == VoiceRouteRig.scratch)
        } catch {
            await finish(env, rig: rig)
            throw error
        }
        await finish(env, rig: rig)
    }

    private func finish(_ env: Setup, rig: VoiceRouteRig) async {
        await env.router.shutdown()
        await env.listener.stop()
        await rig.listener.stop()
    }

    private struct Setup {
        let session: HostSession
        let listener: WebSocketListener
        let router: AmbientRightyoRouter
    }

    private func setup(_ fake: FakeRightyo, rig: VoiceRouteRig) async throws -> Setup {
        let routes = try VoiceRouteRig.routes()
        let session = try await rig.session(selecting: VoiceRouteRig.deck, routes: routes)
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer().naming(routes), hostName: "mac-test"
        )
        await listener.installFallbackSyntheticPeers([session])
        let router = AmbientRightyoRouter(configuration: .init(
            executable: fake.executable, config: fake.config, target: VoiceRouteRig.scratch, binding: "s",
            allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 2)
        ))
        router.attach(listener)
        return Setup(session: session, listener: listener, router: router)
    }

    @Test func configuredTargetKeepsItsAdmissionBindingAfterTheListingChanges() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let rig = try await VoiceRouteRig.make()
        await rig.adapter.setTargets([AdapterTarget(name: "scratch", binding: "rebound")])
        let router = AmbientRightyoRouter(configuration: .init(
            executable: fake.executable, config: fake.config, target: VoiceRouteRig.scratch, binding: "s",
            allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 2)
        ))
        router.attach(rig.listener)
        let stream = UUID()
        router.ambientAudio(.admittedStart(stream: stream, connection: UUID(), target: VoiceRouteRig.scratch,
                                          binding: "admitted-binding",
                                          policy: rig.host.targetPolicy.snapshot(for: VoiceRouteRig.scratch)))
        // The router keeps the authored admission binding; startup hints never override a stream scope.
        #expect(router.activeStream == stream)
        #expect(router.state.withLock { $0.active?.binding == "admitted-binding" })
        router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(router)
        await router.shutdown()
        await rig.listener.stop()
    }
    @Test func streamTargetsAreClearedByStopAndShutdownAndNeverSetWhileClosed() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let router = AmbientRightyoRouter(configuration: .init(
            executable: fake.executable, config: fake.config, target: VoiceRouteRig.scratch, binding: "s",
            allowSynthetic: true
        ))
        let connection = UUID(), other = UUID()
        router.state.withLock { state in
            state.streamTargets = [connection: VoiceRouteRig.scratch, other: VoiceRouteRig.scratch]
            // Retain the teardown mark while an in-flight child could still call back, as the real worker does.
            (state.working, state.reloading) = (true, true)
        }
        router.stop(connection: connection)
        #expect(router.state.withLock { $0.streamTargets[connection] == nil && $0.closed.contains(connection) })
        router.ambientAudio(.started(stream: UUID(), connection: connection, target: VoiceRouteRig.scratch))
        #expect(router.state.withLock { $0.streamTargets[connection] == nil })
        router.state.withLock { $0.reloading = false }
        await router.shutdown()
        #expect(router.state.withLock { $0.streamTargets.isEmpty })
        router.ambientAudio(.started(stream: UUID(), connection: other, target: VoiceRouteRig.scratch))
        #expect(router.state.withLock { $0.streamTargets.isEmpty })
    }
}
#endif
