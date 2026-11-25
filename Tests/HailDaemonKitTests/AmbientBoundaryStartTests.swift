#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// A reload reads its routes while constructing the replacement, with the event queue still held.
private struct ReloadRoutes: HostSessionAuthorizing {
    let base = ConnectionProbeAuthorizer()
    let onRead: @Sendable () -> Void
    var capabilities: [String] { base.capabilities }
    var voiceRoutes: VoiceRoutes? { onRead(); return base.voiceRoutes }
    func authorize(_ frame: Frame) async -> HostSessionAuthorization { await base.authorize(frame) }
}

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryStartTests {
    typealias Rig = AmbientBoundaryRig

    private func duringReload(_ rig: Rig, _ enqueue: @escaping @Sendable () -> Void) async throws {
        let routes = ReloadRoutes {
            rig.router.attach(rig.env.listener)
            #expect(rig.router.state.withLock { $0.reloading })
            enqueue()
        }
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: rig.env.rig.host,
                                             authorizer: routes, ambient: rig.router)
        defer {
            withExtendedLifetime(listener) {}
            rig.router.attach(rig.env.listener)
        }
        try #require(await rig.router.reload() == .reloaded)
    }

    @Test func reusedWireIDStartsANewPrivacyAdmission() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            let successor = UUID()
            try await duringReload(rig) {
                // Drive the gate's events directly after its ended-ID history has forgotten this wire ID.
                rig.router.ambientAudio(.ended(stream: rig.stream, reason: .final))
                rig.start(rig.stream, on: successor)
                rig.send(Rig.marker, 0)
                rig.off()
                rig.send(Rig.later, 1)
            }
            try #require(await eventually { rig.router.activeConnection() == successor })
            let child = try rig.active()
            #expect(try await rig.end() == Rig.later)
            #expect(try !rig.arguments(child).contains("--start-private"))
        }
    }

    @Test func restoredStartUsesItsOwnPrivacyBeforeRegistration() async throws {
        let stream = UUID(), context = Mutex<(AmbientRightyoRouter, UUID)?>(nil)
        let beforeRegistration: @Sendable (UUID) -> Void = { owner in
            guard let (router, source) = context.withLock({ $0 }) else { return }
            #expect(router.state.withLock { state in
                state.working && state.active == nil && state.duck[owner] != nil &&
                    state.privacySources[owner]?.connection == source
            })
            router.ambientPrivacy(false, connection: owner)
            #expect(!router.duckMode(connection: owner) && router.duckMode(connection: source))
            router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: Rig.later))
            router.ambientPrivacy(false, connection: source)
        }
        try await Rig.withRig(childMade: beforeRegistration) { rig in
            let peer = try await FallbackSocketPair.boundedConnect(
                port: rig.env.port, selecting: [RecipientTestRig.target], capabilities: [DuckMode.capability]
            )
            defer { peer.close() }
            let peers = await RestoreRig.connections(of: rig.env.listener)
            let source = try #require(peers.subtracting([rig.connection]).first)
            rig.router.ambientPrivacyPreArm(connection: source)
            try #require(rig.router.duckMode(connection: source))
            context.withLock { $0 = (rig.router, source) }
            defer { context.withLock { $0 = nil } }
            // Put this start on the worker so its segment can queue during construction.
            rig.router.state.withLock { $0.reloading = true }
            rig.start(stream)
            rig.router.state.withLock { $0.reloading = false }
            try #require(await eventually { rig.router.activeStream == stream })
            let child = try rig.active()
            try #require(await eventually { child.childStarted && !child.privacyControl.active })
            #expect(try await rig.end(stream) == Rig.later)
        }
    }

    /// #1341 accepts one bounded silence gap for an interior private slot dropped before the child exists.
    @Test func acceptedBoundedSilenceForQueuedPrivateSlot1341() async throws {
        try await Rig.withRig { rig in
            rig.start()
            let first = try rig.active(), next = UUID()
            try #require(await eventually { first.childStarted })
            try await duringReload(rig) {
                rig.router.ambientAudio(.ended(stream: rig.stream, reason: .superseded))
                rig.start(next)
                rig.send(Rig.prefix, 0, on: next)
                rig.router.ambientPrivacy(true, connection: rig.connection)
                #expect(rig.router.duckMode(connection: rig.connection))
                rig.send(Rig.marker, 1, on: next)
                rig.off()
            }
            try #require(await eventually { rig.router.activeStream == next })
            let child = try rig.active()
            try #require(await eventually { child.counters.writtenBytes >= Rig.prefix.count })
            rig.clock.advance(.seconds(1))
            rig.send(Rig.later, 2, on: next)
            let heard = try await rig.end(next)
            #expect(heard.starts(with: Rig.prefix) && heard.suffix(Rig.later.count) == Rig.later)
            let gap = heard.dropFirst(Rig.prefix.count).dropLast(Rig.later.count)
            #expect(gap.count <= 3_200 && gap.allSatisfy { $0 == 0 })
        }
    }
}
#endif
