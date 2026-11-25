#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// makePipeline reads voice routes after taking the launch wish and before constructing the child.
private struct BoundaryRoutes: HostSessionAuthorizing {
    let base: any HostSessionAuthorizing
    let whenRead: @Sendable () -> Void
    var capabilities: [String] { base.capabilities }
    var voiceRoutes: VoiceRoutes? { whenRead(); return base.voiceRoutes }
    func authorize(_ frame: Frame) async -> HostSessionAuthorization { await base.authorize(frame) }
}

extension AmbientBoundaryRig {
    fileprivate func launchListener(_ whenRead: @escaping @Sendable () -> Void) throws -> WebSocketListener {
        try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: env.rig.host,
                              authorizer: BoundaryRoutes(base: ConnectionProbeAuthorizer(), whenRead: whenRead),
                              ambient: router)
    }
}

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryLaunchTests {
    typealias Rig = AmbientBoundaryRig

    @Test func successorOnSameConnection() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            rig.off()
            let next = UUID()
            rig.router.state.withLock { $0.reloading = true }
            rig.router.ambientAudio(.ended(stream: rig.stream, reason: .superseded))
            rig.start(next)
            rig.send(Rig.later, 0, on: next)
            rig.router.state.withLock { $0.reloading = false }
            try #require(await eventually { rig.router.activeStream == next })
            #expect(try await rig.end(next) == Rig.later)
        }
    }

    @Test func offDuringPrivateConstruction() async throws {
        let box = RouterBox(), stream = UUID()
        let atSpawn: @Sendable (UUID) -> Void = { connection in
            guard let router = box.value.withLock({ $0 }) else { return }
            router.ambientPrivacy(false, connection: connection)
            router.ambientAudio(.segment(stream: stream, sequence: 0, bytes: Rig.later))
        }
        try await Rig.withRig(childMade: atSpawn) { rig in
            box.value.withLock { $0 = rig.router }
            rig.router.ambientPrivacyPreArm(connection: rig.connection)
            rig.router.state.withLock { $0.reloading = true }
            rig.start(stream)
            rig.router.state.withLock { $0.reloading = false }
            try #require(await eventually { rig.router.activeStream == stream })
            let child = try rig.active()
            #expect(!rig.router.duckMode(connection: rig.connection))
            try #require(await eventually { child.childStarted && !child.privacyControl.active })
            #expect(try await rig.end(stream) == Rig.later)
            #expect(try rig.arguments(child).contains("--start-private"))
        }
    }

    @Test func reloadAcrossOff() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            let listener = try rig.launchListener {
                #expect(rig.router.state.withLock { $0.reloading })
                rig.off()
                rig.send(Rig.later, 0)
            }
            defer {
                withExtendedLifetime(listener) {}
                rig.router.attach(rig.env.listener)
            }
            try #require(await rig.router.reload() == .reloaded)
            let child = try rig.active()
            #expect(try await rig.end() == Rig.later)
            #expect(try rig.arguments(child).contains("--start-private"))
        }
    }

    @Test func failedConstructionAfterDisconnect() async throws {
        try await Rig.withRig { rig in
            let router = rig.router
            router.ambientPrivacyPreArm(connection: rig.connection)
            await router.mediaNotices.queued {}.value
            let saved = rig.fake.directory.appendingPathComponent("saved-config")
            let listener = try rig.launchListener {
                #expect(router.duckMode(connection: rig.connection))
                rig.off()
                router.stop(connection: rig.connection)
                do {
                    try FileManager.default.moveItem(at: rig.fake.config, to: saved)
                } catch { Issue.record("Could not move fixture configuration") }
            }
            defer { withExtendedLifetime(listener) {} }
            rig.start()
            try #require(rig.events.list.withLock {
                $0.contains { $0.event == "ambient_refused" && $0.detail == "child unsafeConfig" }
            })
            #expect(router.liveRuns == 0 && router.state.withLock { $0.parks.isEmpty && !$0.parkOverflow })
            router.attach(rig.env.listener)
            try FileManager.default.moveItem(at: saved, to: rig.fake.config)
            let next = UUID()
            rig.start(next, on: UUID())
            let child = try rig.active()
            rig.send(Rig.later, 0, on: next)
            #expect(try await rig.end(next) == Rig.later)
            #expect(try !rig.arguments(child).contains("--start-private"))
        }
    }
}
#endif
