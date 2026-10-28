#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #904 (#967, Jarvis: privacy wins ties): an unsourced pre-arm whose `duck_mode` notice finds its device gone is
/// parked by teardown's own `parkPrivacy`, so a device that may already hold its confirmation is never left believing
/// in privacy the host dropped. A connection id with no peer stands for the window in which the listener has dropped the
/// peer but not yet torn the connection down. Real loopback listener and fake RightyO; synthetic only, waits bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyPreArmDisarmTests {
    /// Another device's fresh start restores the park, private: launched `--start-private` as the rig's first child.
    static func nextStartRestoresThePark(_ rig: RestoreRig) async throws {
        let (_, other) = try await rig.start(name: "other", kind: "pad")
        #expect(rig.router.duckMode(connection: other))
        #expect(await eventually { rig.details("ambient_privacy_restored").first?.contains("source=park") == true },
                "restored from the park marker")
        await rig.finish()
        #expect((try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == true)
    }

    /// Holds the router's notice queue until the returned call, so an arming can be read (or changed) before its
    /// notice runs.
    static func holdNotices(_ router: AmbientRightyoRouter) -> @Sendable () -> Void {
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        router.mediaNotices.enqueue { for await _ in held { break } }
        return {
            release.yield()
            release.finish()
        }
    }

    /// The race: the notice finds no connection before the teardown. The arming is parked (one park, its token), the
    /// teardown that follows parks nothing more, and the next start anywhere is private.
    @Test func theRaceParksAndTheNextStartIsPrivate() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (router, gone) = (rig.router, UUID())
        let release = Self.holdNotices(router)
        router.ambientPrivacyPreArm(connection: gone)
        let token = try #require(router.duckArming(connection: gone))
        release()
        #expect(await eventually { rig.details("ambient_privacy_disarmed") == ["reason=no_connection parked=true"] },
                "disarm-park marker")
        router.stop(connection: gone, device: nil)
        #expect(router.state.withLock { $0.parks.count == 1 && $0.parks[gone]?.token == token })
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_privacy_parked") == ["parks=1 overflow=false"])
        try await Self.nextStartRestoresThePark(rig)
    }

    /// At the bound the disarm-park evicts the oldest park and sets the overflow, which stays set through another
    /// pre-arm until the owner's off clears every park and the overflow.
    @Test func theOverflowStaysUntilTheOwnersOff() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (router, gone) = (rig.router, UUID())
        let release = Self.holdNotices(router)
        router.ambientPrivacyPreArm(connection: gone)
        #expect(rig.details("ambient_privacy_prearmed") == ["source=none"])
        let seeded = (1...AmbientRightyoRouter.maxParkedPrivacy).map { _ in UUID() }
        router.state.withLock { state in
            for (sequence, id) in seeded.enumerated() {
                state.parks[id] = ParkedPrivacy(connection: id, device: nil, parkedAt: Date(), sequence: sequence + 1)
            }
        }
        release()
        #expect(await eventually { !rig.details("ambient_privacy_disarmed").isEmpty }, "disarm-park marker")
        #expect(router.state.withLock { state in
            state.parkOverflow && state.parks.count == AmbientRightyoRouter.maxParkedPrivacy
                && state.parks[gone] != nil && state.parks[seeded[0]] == nil
        })
        let (socket, owner) = try await AmbientPrivacyPreArmTests.preArmed(rig)
        #expect(router.state.withLock { $0.parkOverflow }, "the overflow stays through another pre-arm")
        try await AmbientPrivacySwitchTests.send(false, on: socket)
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: false, reason: "device"), on: socket, step: "off")
        #expect(!router.duckMode(connection: owner))
        #expect(router.state.withLock { $0.parks.isEmpty && !$0.parkOverflow })
        await rig.finish()
    }

    /// A newer arming on the connection when the notice runs is neither parked nor undone.
    @Test func aNewerArmingIsNeitherParkedNorUndone() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (router, gone, newer) = (rig.router, UUID(), UUID())
        let release = Self.holdNotices(router)
        router.ambientPrivacyPreArm(connection: gone)
        router.state.withLock { $0.duck[gone] = AmbientDuckTimer(token: newer, timer: nil) }
        release()
        let drained = MeetingLatch()
        router.mediaNotices.enqueue { drained.open() }
        #expect(await eventually { drained.isOpen }, "notice done marker")
        #expect(router.duckArming(connection: gone) == newer)
        #expect(router.state.withLock { $0.parks.isEmpty })
        #expect(rig.details("ambient_privacy_disarmed").isEmpty)
        await rig.finish()
    }
}
#endif
