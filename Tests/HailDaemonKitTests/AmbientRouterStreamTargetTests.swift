#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #327 PR 1: inject STARTED at the router seam; the shipping gate still pins its one target.
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
        let (session, listener, router) = (env.session, env.listener, env.router)
        let stream = UUID(), connection = await session.connectionID
        do {
            router.ambientAudio(.started(stream: stream, connection: connection, target: VoiceRouteRig.deck,
                                         selection: await session.selectionGeneration))
            try #require(await eventually { router.activeStream == stream })
            #expect(router.status().target == VoiceRouteRig.deck)
            #expect(router.state.withLock { $0.active?.target == VoiceRouteRig.deck && $0.active?.binding == "d" })
            router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: Data(count: 3_200)))
            if reload {
                try #require(await eventually { fakeFileSize(fake, "original.bin") == 3_200 })
                try rewriteFake(fake, behavior)
                #expect(await router.reload() == .reloaded)
                router.ambientAudio(.segment(stream: stream, sequence: 1, bytes: Data(count: 3_200)))
            }
            router.ambientAudio(.ended(stream: stream, reason: .final))
            await boundedSettle(router)
            let deliveries = await rig.adapter.deliveries
            try #require(deliveries.count == 1)
            #expect(deliveries[0].target == (routed ? "scratch" : "deck"))
            #expect(deliveries[0].binding == (routed ? "s" : "d"))
            // Routing to scratch must still retain STARTED's deck as the dispatcher's source.
            #expect(blockReference(in: deliveries[0].text) != nil)
            #expect(router.streamTarget(on: connection) == VoiceRouteRig.deck)
            #expect(router.status().target == VoiceRouteRig.deck)
        } catch {
            await router.shutdown()
            await listener.stop()
            await rig.listener.stop()
            throw error
        }
        await router.shutdown()
        await listener.stop()
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
            executable: fake.executable, config: fake.config, target: VoiceRouteRig.deck, binding: "d",
            allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 2)
        ))
        router.attach(listener)
        return Setup(session: session, listener: listener, router: router)
    }

    @Test(arguments: [false, true])
    func aDifferentTargetIsRefusedInlineWithoutDelayingTheConfiguredStart(workerHeld: Bool) async throws {
        let fake = try FakeRightyo("echo launched > launched.txt\n/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let rig = try await VoiceRouteRig.make()
        let made = Mutex(0), events = DuckEvents()
        var config = AmbientRightyoRouter.Configuration(
            executable: fake.executable, config: fake.config, target: VoiceRouteRig.scratch, binding: "s",
            allowSynthetic: true, timing: .init(eofGrace: 0.1, termGrace: 0.1)
        )
        config.childMade = { _ in made.withLock { $0 += 1 } }
        let router = AmbientRightyoRouter(configuration: config, log: { event in
            events.list.withLock { $0.append(event) }
        })
        router.attach(rig.listener)
        if workerHeld { router.state.withLock { ($0.working, $0.reloading) = (true, true) } }
        let refused = UUID(), stream = UUID(), connection = UUID()
        // Deck is listed, alive and policy-bound: PR 1 still refuses it without consulting that listing.
        router.ambientAudio(.started(stream: refused, connection: connection, target: VoiceRouteRig.deck))
        #expect(events.list.withLock { $0.map { "\($0.event):\($0.detail ?? "")" } }
                == ["ambient_refused:target_binding_unavailable"])
        #expect(made.withLock { $0 } == 0)
        #expect(router.liveRuns == 0 && router.activeStream == nil && router.state.withLock { $0.queue.isEmpty })
        #expect(fakeFileSize(fake, "launched.txt") == -1)
        let start = AmbientAudioEvent.started(stream: stream, connection: connection, target: VoiceRouteRig.scratch)
        let segment = AmbientAudioEvent.segment(stream: stream, sequence: 0, bytes: Data(count: 3_200))
        let end = AmbientAudioEvent.ended(stream: stream, reason: .final)
        router.ambientAudio(start)
        router.ambientAudio(segment)
        if workerHeld {
            router.ambientAudio(end)
            #expect(router.state.withLock { $0.queue } == [start, segment, end])
            router.state.withLock { $0.reloading = false }
        } else {
            #expect(router.activeStream == stream)
            #expect(made.withLock { $0 } == 1)
            router.ambientAudio(end)
        }
        try #require(await eventually { made.withLock { $0 } == 1 && router.state.withLock { !$0.working } })
        await boundedSettle(router)
        #expect(events.list.withLock { $0.map(\.event) } == ["ambient_refused", "ambient_started", "ambient_ended"])
        await router.shutdown()
        await rig.listener.stop()
    }

    @Test func configuredTargetKeepsItsStartupBindingAfterTheListingChanges() async throws {
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
        router.ambientAudio(.started(stream: stream, connection: UUID(), target: VoiceRouteRig.scratch))
        // Configured-target starts remain inline and retain the original binding; dispatch still checks policy.
        #expect(router.activeStream == stream)
        #expect(router.state.withLock { $0.active?.binding == "s" })
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
