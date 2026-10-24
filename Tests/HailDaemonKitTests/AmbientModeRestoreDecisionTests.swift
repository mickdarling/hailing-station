#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #735 meeting mode restore (MM-E), review round 3: privacy taken elsewhere never ends a listening connection's mode,
/// and a restore's recording decision reaches the state and every hook even after a renewal or profile switch that
/// landed first. Synthetic devices only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientModeRestoreDecisionTests {
    /// R3-1: the daemon-wide privacy end (a privacy entry taken on another connection, such as a retiring child's) ends
    /// a stale holder only. The connection listening now keeps its meeting, its gate and its hook history.
    @Test func aListeningHolderKeepsItsMeetingThroughPrivacyElsewhere() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        let (first, listening) = try await rig.start()
        #expect(try await rig.confirmation(on: first) == MeetingRig.on.text)
        #expect(await eventually { rig.control(1) == RestoreRig.gate }, "listener gate marker")
        let (_, stale) = try await rig.connect()
        let router = rig.router
        #expect(router.setMeeting(on: true, connection: stale, reason: "voice") == 0)
        router.state.withLock { router.endEveryMode(reason: "privacy", except: UUID(), in: &$0) }
        #expect(router.meetingMode(connection: listening) && !router.meetingMode(connection: stale))
        #expect(await eventually { rig.changes.count == 3 }, "stale holder privacy hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "voice", "privacy"])
        #expect(rig.changes.last?.connection == stale)
        #expect(await eventually { rig.details("ambient_mode_ended").count == 1 }, "stale holder ended log marker")
        #expect(rig.details("ambient_mode_ended").first?.contains("from=\(stale)") == true)
        await rig.finish()
        #expect(rig.control(1) == RestoreRig.gate)
    }

    /// R3-2: the restore's decision lands after a renewal (or profile switch) that replaced its arming; the stored
    /// value and every hook still agree on it.
    @Test(arguments: [false, true]) func aDecisionAfterARenewalStillAgrees(_ switchProfile: Bool) async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let latch = MeetingLatch(), router = rig.router
        router.meetingChanges.enqueue { await latch.wait() }
        let (_, connection) = try await rig.start()
        #expect(router.meetingMode(connection: connection))
        let profile: MeetingProfile = switchProfile ? .rubberDuck : .meeting
        #expect(router.setMeeting(on: true, profile: profile, connection: connection, reason: "voice") == 1)
        // Not yet decided: the placeholder errs toward not recording.
        #expect(router.state.withLock { $0.meeting[connection]?.recording } == false)
        latch.open()
        #expect(await eventually { rig.changes.count == (switchProfile ? 4 : 3) }, "decision hook marker")
        let resumed = try #require(rig.changes.first { $0.reason.hasPrefix("resumed") })
        #expect(resumed.reason == "resumed" && resumed.recording)
        #expect(router.state.withLock { $0.meeting[connection]?.recording } == true)
        if switchProfile {
            #expect(rig.changes.last?.profile == .rubberDuck && rig.changes.last?.recording == true)
        }
        await rig.finish()
    }
    /// R4-1: a decision whose arming moved away is stale even when the meeting comes back to the same connection
    /// before it runs. Restore onto A, move to B, move back to A, all before the first decision: the two stale ones
    /// are dropped (unrecorded), and the state and the last hook carry only the last decision.
    @Test func aStaleDecisionNeverLandsOnALaterArming() async throws {
        let rig = try await RestoreRig()
        defer { rig.close() }
        _ = try await AmbientModeRestoreTests.meetingDropped(rig)
        let latch = MeetingLatch(), router = rig.router
        router.meetingChanges.enqueue { await latch.wait() }
        let (phone, home) = try await rig.start()
        _ = try await rig.start(name: "other", kind: "pad")
        try await recipientSocketSend(audio(UUID(), 0), on: phone)
        #expect(await eventually { router.activeConnection() == home }, "back home marker")
        #expect(router.meetingMode(connection: home))
        latch.open()
        #expect(await eventually { rig.changes.count == 7 }, "three restores hook marker")
        #expect(rig.changes.map(\.reason) == ["voice", "connection", "resumed_unrecorded", "moved",
                                              "resumed_unrecorded", "moved", "resumed_unrecorded"])
        #expect(rig.changes.allSatisfy { !$0.recording || $0.reason == "voice" })
        #expect(router.state.withLock { $0.meeting[home]?.recording } == false)
        #expect(await eventually { rig.details("meeting_restored").count == 3 }, "three decisions marker")
        let decisions = rig.details("meeting_restored").map { $0.hasSuffix("decision=stored") }
        #expect(decisions == [false, false, true])
        // The first, stale, decision matched (same claims, recorded source), yet it never reached hook or state.
        #expect(rig.details("meeting_restored").first?.contains("recording=false device_match=true") == true)
        await rig.finish()
    }
}
#endif
