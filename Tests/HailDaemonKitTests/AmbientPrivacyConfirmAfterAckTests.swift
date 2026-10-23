#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The privacy-on confirmation follows the child's ack (#735 S-8 HS-C): `confirm-privacy-on/` plays only once every
/// child proved it keeps privacy. Without the proof no privacy-on clip plays, and a refused child's "I can't listen
/// privately right now." speaks once. The device's `duck_mode` stays immediate. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyConfirmAfterAckTests {
    static let holdAcks = "while [ ! -e go ]; do /bin/sleep 0.02; done\n"
    static let privacyOn = "Privacy on. I'm only listening for my name."
    static let unavailable = "unavailable confirm=confirmprivacyunavailable/0:sent"

    /// The owner's entry; the child acks it only once the test creates `go`.
    static let heldEntry = FakeRightyo.ackingControl() + "\n" + AmbientPrivacyEventTests.enterThen([])
        .replacingOccurrences(of: FakeRightyo.ackingTail, with: holdAcks + FakeRightyo.ackingTail)
    /// The owner's entry from a child that records its control lines and never acks.
    static let neverAcked = "/bin/cat <&3 > control.txt &\n" + AmbientPrivacyEventTests.enterThen([])
        .replacingOccurrences(of: FakeRightyo.ackingTail, with: "/bin/cat > /dev/null\nwait\n")
    /// The switch's started child (status answered), acking only once the test creates `go`; `acks` false: never.
    static func heldSwitch(acks: Bool = true) -> String {
        let script = AmbientPrivacySwitchTests.script()
        guard acks else {
            return script.replacingOccurrences(of: FakeRightyo.ackingControl(), with: "/bin/cat <&3 > control.txt &")
                .replacingOccurrences(of: FakeRightyo.ackingTail, with: "/bin/cat > /dev/null\nwait\n")
        }
        return script.replacingOccurrences(of: FakeRightyo.ackingTail, with: holdAcks + FakeRightyo.ackingTail)
    }

    static func control(_ rig: DuckRig) -> String { (try? rig.fake.recorded("control.txt")) ?? "" }

    /// Held ack: the device hears `duck_mode` at once, but no clip plays until the ack; then only the privacy-on clip.
    @Test func thePrivacyOnClipWaitsForTheAck() async throws {
        let rig = try await DuckRig(script: Self.heldEntry, clips: AmbientDuckModeTests.clips,
                                    capabilities: [DuckMode.capability])
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_device") == ["on=true device=sent"] })
        #expect(Self.control(rig) == "{\"duck\":true}\n")
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.details("ambient_duck_confirmed").isEmpty)
        AmbientPrivacyAckGateTests.go(rig.fake)
        let (before, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "privacy on")
        #expect(words == Self.privacyOn)
        #expect(before.contains(.control(.duckMode(on: true, reason: "voice"))))
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle confirm=confirmprivacyon/0:sent"])
    }

    /// No ack by the (short) deadline: no privacy-on clip, the child is refused, and exactly one unavailable clip.
    @Test func noAckByTheDeadlineSaysOnlyUnavailable() async throws {
        let rig = try await DuckRig(script: Self.neverAcked, clips: AmbientDuckModeTests.clips, ackDeadline: 0.3)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        let (_, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "unavailable")
        #expect(words == "I can't listen privately right now.")
        let settled = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true unacknowledged playback=idle confirm=unreported",
                                                          Self.unavailable])
        #expect(!settled.contains { $0.contains("confirmprivacyon") })
        #expect(rig.details("ambient_privacy_start") == ["outcome=refused reason=unacknowledged"])
        #expect(Self.control(rig) == "{\"duck\":true}\n")
    }

    /// Off before the ack: the entry plays no privacy-on clip (nor stops playback); only "Recording again." plays.
    @Test func offBeforeTheAckPlaysNoPrivacyOnClip() async throws {
        let rig = try await DuckRig(script: FakeRightyo.ackingControl() + "\n"
                                        + AmbientPrivacyEventTests.enterThen(["exit"], acked: false),
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true unacknowledged confirm=unreported",
                                                          "on=false confirm=confirmprivacyoff/0:sent"])
        #expect(rig.details("ambient_ended").count == 1 && rig.details("ambient_privacy_start").isEmpty)
    }

    /// The app's switch waits for the ack too: `duck_mode` at once, then the stop and the privacy-on clip after it.
    @Test func theSwitchWaitsForTheAck() async throws {
        let rig = try await DuckRig(script: Self.heldSwitch(), clips: AmbientDuckModeTests.clips,
                                    capabilities: [DuckMode.capability, PlaybackStop.capability])
        defer { rig.close() }
        let statusOff = AmbientPrivacySwitchTests.statusOff
        #expect(await eventually { rig.details("ambient_duck_confirmed") == [statusOff] })
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        #expect(await eventually { rig.details("ambient_duck_device") == ["on=true device=sent"] })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.details("ambient_duck_confirmed") == [statusOff])
        AmbientPrivacyAckGateTests.go(rig.fake)
        let (before, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "privacy on")
        #expect(words == Self.privacyOn)
        let notice = before.firstIndex(of: .control(.duckMode(on: true, reason: "device")))
        let stop = before.firstIndex(of: .control(.stopPlayback))
        #expect(notice != nil && stop != nil && (notice ?? 0) < (stop ?? 0))
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == [
            statusOff, "on=true reason=device playback=stopped confirm=confirmprivacyon/0:sent"
        ])
    }

    /// The switch with no ack by the deadline: no privacy-on clip, one unavailable clip; privacy stays on.
    @Test func theSwitchWithoutAnAckSaysOnlyUnavailable() async throws {
        let rig = try await DuckRig(script: Self.heldSwitch(acks: false), clips: AmbientDuckModeTests.clips,
                                    capabilities: [DuckMode.capability], ackDeadline: 0.3)
        defer { rig.close() }
        let statusOff = AmbientPrivacySwitchTests.statusOff
        #expect(await eventually { rig.details("ambient_duck_confirmed") == [statusOff] })
        let connection = try #require(rig.connection())
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
        let settled = await rig.settledEvents()
        #expect(rig.env.router.duckMode(connection: connection))
        await rig.finish()
        #expect(!settled.contains { $0.contains("confirmprivacyon") })
        #expect(Set(rig.details("ambient_duck_confirmed")) == [
            statusOff, "on=true reason=device unacknowledged playback=idle confirm=unreported", Self.unavailable
        ])
        #expect(rig.details("ambient_duck_confirmed").filter { $0 == Self.unavailable }.count == 1)
    }

    /// A reload swaps out the child before it acked: its successor, started private (its `started` is the proof),
    /// answers for it, so the privacy-on clip still plays, once.
    @Test func aChildReloadedBeforeItsAckIsAnsweredForByItsSuccessor() async throws {
        let first = AmbientDuckReloadTests.entry
            .replacingOccurrences(of: FakeRightyo.ackingTail, with: Self.holdAcks + FakeRightyo.ackingTail)
        let later = """
        \(AmbientPrivacyEntryTests.startPrivatePrelude)
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(FakeRightyo.duckV3)
        \(FakeRightyo.ackingTail)
        """
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(first, later),
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.details("ambient_duck_confirmed").isEmpty)
        #expect(await rig.env.router.reload() == .reloaded)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        let settled = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle confirm=confirmprivacyon/0:sent"])
        #expect(!settled.contains { $0.contains("unavailable") })
    }

    /// A v2 child never acks: the entry is refused with "Nothing was sent.", never the privacy-on clip, and the router
    /// answers false for it, as for a connection with no run.
    @Test func aVersionTwoChildNeverHearsPrivacyOn() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true, version: 2,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(try await rig.confirmation() == "Nothing was sent.")
        let connection = try #require(rig.connection())
        #expect(await rig.env.router.privacyKept(connection: connection) == false)
        #expect(await rig.env.router.privacyKept(connection: UUID()) == false)
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == [
            "on=true refused=unsupported_version confirm=confirmnotsent/0:sent"
        ])
    }
}
#endif
