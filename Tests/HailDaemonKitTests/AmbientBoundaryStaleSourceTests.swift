#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// makePipeline reads the routes synchronously while reload holds its slot.
private struct StaleSourceReloadRoutes: HostSessionAuthorizing {
    let base = ConnectionProbeAuthorizer()
    let duringReload: @Sendable () -> Void
    var capabilities: [String] { base.capabilities }
    var voiceRoutes: VoiceRoutes? { duringReload(); return base.voiceRoutes }
    func authorize(_ frame: Frame) async -> HostSessionAuthorization { await base.authorize(frame) }
}

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryStaleSourceTests {
    typealias Rig = AmbientBoundaryRig

    @Test func reusedStreamKeepsTheNewOwnersPublicSegment() async throws {
        try await Rig.withRig { rig in
            let peer = try await FallbackSocketPair.boundedConnect(
                port: rig.env.port, selecting: [RecipientTestRig.target], capabilities: [DuckMode.capability]
            )
            defer { peer.close() }
            let peers = await RestoreRig.connections(of: rig.env.listener)
            let other = try #require(peers.subtracting([rig.connection]).first)
            // Both latest entries survive normal ends. Swap roles on those same keys so either dictionary
            // iteration order exercises the stale-owner-first case.
            try await reuse(rig, source: rig.connection, successor: other)
            try await reuse(rig, source: other, successor: rig.connection)
        }
    }

    private func reuse(_ rig: Rig, source: UUID, successor: UUID) async throws {
        let router = rig.router, shared = UUID(), beforeReload = UUID()
        rig.start(shared, on: source)
        let first = try rig.active()
        try #require(await eventually { first.childStarted })
        router.ambientPrivacy(true, connection: source)
        try #require(await first.privacyKept())
        let token = try #require(router.duckArming(connection: source))
        _ = try await rig.end(shared)
        router.endStaleSource(.init(connection: source, token: token), verdict: "stale", off: successor,
                              notSources: [], reason: "device")
        try #require(router.state.withLock { $0.staleCleared[source] == token })

        rig.start(beforeReload, on: successor)
        let prior = try rig.active()
        try #require(await eventually { prior.childStarted })
        let routes = StaleSourceReloadRoutes {
            router.attach(rig.env.listener)
            #expect(router.state.withLock { $0.reloading })
            router.ambientAudio(.ended(stream: beforeReload, reason: .final))
            rig.start(shared, on: successor)
            #expect(router.isLatest(stream: shared, connection: source))
            #expect(router.isLatest(stream: shared, connection: successor))
            rig.send(Rig.marker, 0, on: shared)
            #expect(router.state.withLock { $0.queue.count == 3 && $0.staleCleared[source] == token })
            router.ambientPrivacy(false, connection: source)
            #expect(!router.duckMode(connection: source) && !router.duckMode(connection: successor))
        }
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.env.rig.host,
                                             authorizer: routes, ambient: router)
        defer {
            withExtendedLifetime(listener) {}
            router.attach(rig.env.listener)
        }
        try #require(await router.reload() == .reloaded)
        try #require(await eventually { router.activeStream == shared && router.activeConnection() == successor })
        let child = try rig.active()
        rig.send(Rig.later, 1, on: shared)
        #expect(try await rig.end(shared) == Rig.marker + Rig.later)
        #expect(try !rig.arguments(child).contains("--start-private"))
        try #require(await eventually { router.state.withLock { !$0.working && $0.runs.isEmpty } })
    }
}
#endif
