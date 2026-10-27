#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// #961: privacy is parked per dropped connection, not in one slot. A stale verdict drops only the park its own source
/// and arming made, so another device's privacy parked meanwhile survives it; past the bound the oldest park is
/// evicted and an overflow keeps every fresh start private until the owner's off. Every device sends the app's own
/// claims (Hello name "hail terminal", class `phone`). Real loopback listener and fake RightyO; synthetic only, every
/// wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkSetTests {
    /// The #961 window. An owner's off on B probes B's restore source A (silent). Inside that window, before the
    /// verdict (the `offScoping` hook), a second private device C drops and parks, then A drops and parks. The stale
    /// verdict drops only A's park, so C's reconnect starts private (`--start-private`), and no PCM reaches its child
    /// before its private proof.
    @Test func aStaleVerdictDropsOnlyItsOwnPark() async throws {
        let window = WindowBox()
        let settings = PrivacyOffSettings(probeTimeout: .milliseconds(500), offScoping: { _ in
            await window.value.withLock { $0 }?()
        })
        let (scene, silent) = try await AmbientPrivacyOffScopeTests.restoredFrom(silent: true, privacy: settings)
        let (rig, router) = (scene.rig, scene.rig.router)
        let peer = try #require(silent)
        defer { peer.cancel(); rig.close() }
        // C: another private device, restored from A, its child confirmed private.
        let (other, device) = try await rig.start(name: RestoreRig.appName)
        try #require(await eventually { router.duckMode(connection: device) }, "second device private")
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "second device's child private")
        window.value.withLock { $0 = { [source = scene.source] in
            other.cancel(with: .goingAway, reason: nil)
            if await eventually({ router.state.withLock { $0.parks[device] != nil } }) {
                window.parked.withLock { $0.append(device) }
            }
            peer.cancel()
            if await eventually({ router.state.withLock { $0.parks[source] != nil } }) {
                window.parked.withLock { $0.append(source) }
            }
        } }
        let line = await AmbientPrivacyOffScopeTests.off(scene)
        #expect(window.parked.withLock { $0 } == [device, scene.source], "both parked inside the probe window")
        #expect(line == "cleared=1 kept=1 \(scene.source)=stale \(device)=not_source")
        await rig.drainMeetingChanges()
        #expect(router.state.withLock { Array($0.parks.keys) == [device] && !$0.parkOverflow })
        #expect(rig.details("ambient_privacy_parked") == ["parks=1 overflow=false", "parks=2 overflow=false"])
        #expect(rig.details("ambient_park_discarded") == ["reason=stale mode=privacy parks=1 overflow=false"])
        let (socket, again) = try await rig.start(name: RestoreRig.appName)
        #expect(router.duckMode(connection: again))
        #expect(await eventually {
            rig.details("ambient_privacy_restored").last?.hasPrefix("source=park from=\(device) to=\(again)") == true
        }, "restored from the second device's park marker")
        try await AmbientPrivacyParkTests.expectHeardOnlyPrivately(rig, on: socket, spawn: 4)
    }

    /// Past the bound the oldest park is evicted and the overflow set. Once the stale verdicts of every remaining park
    /// have dropped them, a fresh start is still private, restored from the overflow; the owner's off clears it, and
    /// the next start is public. The real bound (16): 17 private connections are cheap to drop, and no child runs.
    @Test func anOverflowKeepsEveryStartPrivateUntilTheOwnersOff() async throws {
        let rig = try await RestoreRig(speaker: 0)
        defer { rig.close() }
        let router = rig.router
        var dropped: [UUID] = []
        for count in 1...AmbientRightyoRouter.maxParkedPrivacy + 1 {
            let (socket, connection) = try await rig.connect(name: RestoreRig.appName)
            // Made private host-side, as a privacy entry leaves it; its teardown parks it.
            router.state.withLock { $0.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil) }
            await rig.drop(socket, connection)
            #expect(await eventually { rig.details("ambient_privacy_parked").count == count }, "parked marker")
            dropped.append(connection)
        }
        let parks = router.state.withLock { $0.parks }
        #expect(parks.count == AmbientRightyoRouter.maxParkedPrivacy && parks[dropped[0]] == nil)
        #expect(router.state.withLock { $0.parkOverflow })
        #expect(rig.details("ambient_privacy_parked").last == "parks=16 overflow=true")
        await rig.drainMeetingChanges()
        #expect(rig.details("ambient_park_discarded") == ["reason=overflow mode=privacy"])
        // Each remaining park's own stale verdict drops it; the overflow stays.
        for park in parks.values {
            router.endStaleSource(PrivacySource(connection: park.connection, token: try #require(park.token)),
                                  verdict: "stale", off: UUID(), notSources: [], reason: "voice")
        }
        #expect(router.state.withLock { $0.parks.isEmpty && $0.parkOverflow })
        let (_, fresh) = try await rig.start(name: RestoreRig.appName)
        #expect(router.duckMode(connection: fresh))
        #expect(await eventually {
            rig.details("ambient_privacy_restored").last == "source=park from=overflow to=\(fresh) device_match=false"
        }, "restored from the overflow marker")
        #expect(await eventually {
            (try? rig.fake.recorded("argv.1.txt"))?.contains("--start-private") == true
        }, "overflow start-private marker")
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        router.ambientPrivacy(false, connection: fresh)
        #expect(router.state.withLock { $0.parks.isEmpty && !$0.parkOverflow })
        #expect(await eventually {
            rig.details("ambient_park_discarded").last == "reason=off mode=privacy count=0 overflow=true"
        }, "overflow cleared marker")
        let (_, next) = try await rig.start(name: RestoreRig.appName)
        #expect(!router.duckMode(connection: next))
        #expect(await AmbientPrivacyParkTests.launchedPublic(rig, spawn: 2))
        await rig.finish()
    }

    /// The overflow alone is a source (#961): a child is admitted only onto a private connection, a restore takes it
    /// (no connection), and it never counts as heard, while a heard park does.
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

    /// A stale verdict drops a park only for the arming it judged: one parked by a later arming of that connection is
    /// kept (`armed`), and another connection's park is never touched.
    @Test func aStaleVerdictDropsAParkOnlyForTheArmingJudged() {
        let scoped = Mutex<[String]>([])
        let router = AmbientRightyoRouter(configuration: .init(
            executable: URL(fileURLWithPath: "/nonexistent"), config: URL(fileURLWithPath: "/nonexistent"),
            target: RecipientTestRig.target, binding: "binding"
        ), log: { event in
            if event.event == "ambient_privacy_off_scoped" { scoped.withLock { $0.append(event.detail ?? "") } }
        })
        let (judged, other, arming) = (UUID(), UUID(), UUID())
        router.state.withLock {
            $0.parks[judged] = ParkedPrivacy(connection: judged, device: nil, parkedAt: Date(), token: arming,
                                             sequence: 1)
            $0.parks[other] = ParkedPrivacy(connection: other, device: nil, parkedAt: Date(), token: UUID(),
                                            sequence: 2)
        }
        router.endStaleSource(PrivacySource(connection: judged, token: UUID()), verdict: "stale", off: UUID(),
                              notSources: [], reason: "voice")
        #expect(router.state.withLock { $0.parks.count } == 2)
        router.endStaleSource(PrivacySource(connection: judged, token: arming), verdict: "stale", off: UUID(),
                              notSources: [], reason: "voice")
        #expect(router.state.withLock { Array($0.parks.keys) } == [other])
        #expect(scoped.withLock { $0 } == ["cleared=0 kept=1 \(judged)=armed", "cleared=1 kept=0 \(judged)=stale"])
    }
}

/// A step a test sets after its rig exists, run by a hook made before it, and the connections it saw parked.
final class WindowBox: Sendable {
    let value = Mutex<(@Sendable () async -> Void)?>(nil)
    let parked = Mutex<[UUID]>([])
}
#endif
