#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientBoundaryOwnershipTests {
    typealias Rig = AmbientBoundaryRig

    private func withSecondPeer(_ rig: Rig, _ exercise: (UUID) async throws -> Void) async throws {
        let peer = try await FallbackSocketPair.boundedConnect(port: rig.env.port, selecting: [RecipientTestRig.target],
                                                               capabilities: [DuckMode.capability])
        defer { peer.close() }
        let connections = await RestoreRig.connections(of: rig.env.listener)
        let second = try #require(connections.subtracting([rig.connection]).first)
        try await exercise(second)
    }

    @Test func successorRestoresTheOtherWish() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            try await withSecondPeer(rig) { other in
                let router = rig.router
                router.ambientPrivacyPreArm(connection: other)
                rig.off()
                try #require(router.duckMode(connection: other) && !router.duckMode(connection: rig.connection))
                router.ambientAudio(.ended(stream: rig.stream, reason: .superseded))
                let next = UUID()
                rig.start(next)
                let child = try rig.active()
                try #require(await child.privacyKept())
                rig.send(Rig.marker, 0, on: next)
                #expect(router.duckMode(connection: rig.connection) && child.privacyControl.active)
                #expect(try await rig.end(next) == Rig.marker)
                #expect(try rig.arguments(child).contains("--start-private"))
                #expect(try !rig.controls(child).contains("\"duck\":false"))
            }
        }
    }

    @Test func queuedStartBetweenWishes() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            try await withSecondPeer(rig) { other in
                let next = UUID(), router = rig.router
                router.state.withLock { $0.reloading = true }
                defer { router.state.withLock { $0.reloading = false } }
                router.ambientAudio(.ended(stream: rig.stream, reason: .superseded))
                rig.start(next, on: other)
                rig.send(Rig.marker, 0, on: next)
                // Only the source has an arming so far. The queued start has yet to run restorePrivacy.
                try #require(!router.duckMode(connection: other))
                rig.off()
                rig.send(Rig.later, 1, on: next)
                router.state.withLock { $0.reloading = false }
                try #require(await eventually { router.activeStream == next })
                let child = try rig.active()
                #expect(try await rig.end(next) == Rig.later)
                #expect(try !rig.arguments(child).contains("--start-private"))
            }
        }
    }

    @Test func newerParkSurvivesLateStartup() async throws {
        try await Rig.withRig(script: Rig.child(beforeStarted: "IFS= read -r release <&3 || exit 1")) { rig in
            let router = rig.router
            router.ambientPrivacyPreArm(connection: rig.connection)
            rig.start()
            let child = try rig.active()
            rig.off()
            try await withSecondPeer(rig) { other in
                router.ambientPrivacyPreArm(connection: other)
                let token = try #require(router.duckArming(connection: other))
                router.stop(connection: other)
                try #require(router.state.withLock { $0.parks[other]?.token == token })
                try #require(!child.childStarted && child.reportMedia(true))
                try #require(await eventually { child.childStarted && !child.privacyControl.active })
                _ = try await rig.end()
                #expect(router.state.withLock { $0.parks[other]?.token == token })
            }
        }
    }

    @Test func takeoverAfterDelivery() async throws {
        try await Rig.withRig { rig in
            rig.start()
            try await rig.enter()
            let first = try rig.active()
            rig.off()
            try #require(!first.privacyControl.active)
            rig.router.ambientAudio(.ended(stream: rig.stream, reason: .superseded))
            try await withSecondPeer(rig) { other in
                let next = UUID()
                rig.start(next, on: other)
                let child = try rig.active()
                rig.send(Rig.later, 0, on: next)
                #expect(!rig.router.duckMode(connection: other))
                #expect(try await rig.end(next) == Rig.later)
                #expect(try !rig.arguments(child).contains("--start-private"))
            }
        }
    }
}
#endif
