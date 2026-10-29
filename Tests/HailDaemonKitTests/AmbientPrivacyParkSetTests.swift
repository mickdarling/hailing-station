#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #961/#1041: parks stay per connection. Drops after owner-off park again; bounded overflow fails closed.
/// Real loopback listener and fake RightyO; synthetic claims and PCM only, every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkSetTests {
    /// An off precedes both teardowns. Neither later park can be erased by deferred cross-connection work.
    @Test func laterTeardownsPreserveEveryParkAfterOff() async throws {
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true)
        let peer = try #require(silent), rig = scene.rig, router = scene.rig.router
        defer { peer.cancel(); rig.close() }
        let (other, device) = try await rig.start(name: RestoreRig.appName)
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "second device private proof")
        try await AmbientPrivacyOffScopeTests.off(scene)
        await rig.drop(other, device)
        peer.cancel()
        #expect(await eventually { router.state.withLock { $0.parks[scene.source] != nil } }, "source parked later")
        #expect(router.state.withLock { $0.parks.count == 2 && $0.parks[device] != nil && !$0.parkOverflow })
        #expect(await eventually { rig.details("ambient_privacy_parked").count == 2 }, "both park logs queued")
        #expect(rig.details("ambient_park_discarded").isEmpty, "owner-off cannot erase later parks")
        let (socket, again) = try await rig.start(name: RestoreRig.appName)
        #expect(router.duckMode(connection: again))
        #expect(await rig.env.listener.replyHold.holds(again))
        #expect(await eventually {
            rig.details("ambient_privacy_restored").last?.hasPrefix("source=park from=\(scene.source)") == true
        }, "newest park selected without losing the other")
        #expect(router.state.withLock { $0.parks.count == 2 }, "restore consumes neither park")
        try await AmbientPrivacyParkTests.expectHeardOnlyPrivately(rig, on: socket, spawn: 4)
    }

    /// Seventeen real teardowns exercise the cap. Isolate the sticky overflow after checking all retained parks.
    @Test func anOverflowKeepsEveryStartPrivateUntilTheOwnersOff() async throws {
        let rig = try await RestoreRig(speaker: 0)
        defer { rig.close() }
        let router = rig.router
        var dropped: [UUID] = []
        for count in 1...AmbientRightyoRouter.maxParkedPrivacy + 1 {
            let (socket, connection) = try await rig.connect(name: RestoreRig.appName)
            router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
            await rig.drop(socket, connection)
            #expect(await eventually { rig.details("ambient_privacy_parked").count == count }, "parked marker")
            dropped.append(connection)
        }
        let parks = router.state.withLock { $0.parks }
        #expect(parks.count == 16 && parks[dropped[0]] == nil)
        #expect(Set(parks.keys) == Set(dropped.dropFirst()), "only the oldest park is evicted")
        #expect(router.state.withLock { $0.parkOverflow })
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_privacy_parked").last == "parks=16 overflow=true")
        #expect(rig.details("ambient_park_discarded") == ["reason=overflow mode=privacy"])
        // Fixture isolation, not owner-off: prove overflow alone keeps covering repeated fresh starts.
        router.state.withLock { $0.parks = [:] }
        let (_, fresh) = try await rig.start(name: RestoreRig.appName)
        #expect(router.duckMode(connection: fresh))
        #expect(await eventually {
            rig.details("ambient_privacy_restored").last?.contains("source=park from=overflow") == true
        }, "overflow restored")
        let further = try await furtherOverflowStart(rig, after: fresh)
        router.ambientPrivacy(false, connection: further)
        #expect(router.state.withLock { $0.parks.isEmpty && !$0.parkOverflow })
        #expect(await eventually {
            rig.details("ambient_park_discarded").last == "reason=off mode=privacy count=1 overflow=true"
        }, "owner-off clears all existing parked privacy")
        let (_, next) = try await rig.start(name: RestoreRig.appName)
        #expect(!router.duckMode(connection: next))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 3))
        await rig.finish()
    }

    @Test func anOverflowAloneIsAPrivacySourceNeverHeard() throws {
        let connection = UUID()
        var state = AmbientRightyoRouter.State()
        state.parkOverflow = true
        #expect(!AmbientRightyoRouter.admitsPrivacy(connection, in: state))
        let (source, from) = try #require(AmbientRightyoRouter.privacySource(except: connection, in: state))
        #expect(source.token == "park" && from == nil)
        #expect(!AmbientRightyoRouter.privacyHeard(except: connection, in: state))
        let parked = UUID()
        state.parks[parked] = ParkedPrivacy(connection: parked, device: nil, parkedAt: Date(), heard: true)
        #expect(AmbientRightyoRouter.privacyHeard(except: connection, in: state))
        #expect(AmbientRightyoRouter.privacySource(except: connection, in: state)?.1 == parked)
        state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
        #expect(AmbientRightyoRouter.admitsPrivacy(connection, in: state))
    }
}

private extension AmbientPrivacyParkSetTests {
    func furtherOverflowStart(_ rig: RestoreRig, after fresh: UUID) async throws -> UUID {
        let router = rig.router
        #expect(await eventually {
            (try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == true
        }, "overflow start-private marker")
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        // Real teardown parks this holder without clearing or consuming overflow.
        await rig.env.gate.end(connection: fresh)
        router.stop(connection: fresh)
        #expect(router.state.withLock { $0.parks[fresh] != nil && $0.parkOverflow })
        let (_, further) = try await rig.start(name: RestoreRig.appName)
        #expect(router.duckMode(connection: further), "a restore never consumes overflow privacy")
        #expect(await eventually {
            (try? rig.fake.recorded("argv.2.txt"))?.contains("--start-private") == true
        }, "a further connection also launches start-private")
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "further private started confirmed")
        #expect(await rig.env.listener.replyHold.holds(further))
        return further
    }
}
#endif
