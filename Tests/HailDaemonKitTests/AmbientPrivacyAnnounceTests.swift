#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Every privacy entry is announced within a bound (#735 S-8 HS-C round 2): exactly one of `confirm-privacy-on/` or
/// `confirm-privacy-unavailable/` plays for it, never the privacy-on clip without proof. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyAnnounceTests {
    typealias Confirm = AmbientPrivacyConfirmAfterAckTests
    static let unavailable = "confirm=confirmprivacyunavailable/0:sent"
    static let privacyOn = "confirm=confirmprivacyon/0:sent"

    /// The clips said so far, in order: `on` or `unavailable`.
    static func said(_ rig: DuckRig) -> [String] {
        rig.details("ambient_duck_confirmed").compactMap { detail in
            detail.hasSuffix(privacyOn) ? "on" : detail.hasSuffix(unavailable) ? "unavailable" : nil
        }
    }

    /// 1. A child that never starts, privacy entered after its start deadline passed unwished: a fresh deadline
    /// refuses it, `unavailable` plays within the bound, and another connection's switch clip is not held behind it.
    @Test func anEntryAfterTheStartDeadlineIsAnnouncedWithinTheBound() async throws {
        let rig = try await DuckRig(script: "/bin/cat > /dev/null\n", clips: AmbientDuckModeTests.clips,
                                    startDeadline: 0.3, confirmTimeout: 2)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        try await Task.sleep(for: .milliseconds(600))
        let began = ContinuousClock.now
        rig.env.router.ambientPrivacy(true, connection: connection)
        rig.env.router.switchPrivacy(true, connection: UUID(), armedAs: nil)
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        #expect(began.duration(to: .now) < .seconds(2))
        // Each connection has its own clip chain (round 3): the other's clip never waits behind this one.
        let confirmed = rig.details("ambient_duck_confirmed")
        #expect(confirmed.contains("on=true reason=device refused playback=idle " + Self.unavailable))
        #expect(confirmed.first?.hasPrefix("on=true reason=device refused=unsupported_version") == true)
        // The run's own end is logged after its refusal was said.
        #expect(await eventually { rig.details("ambient_privacy_start") == ["outcome=refused reason=unconfirmed"] })
        await rig.finish()
        #expect(Self.said(rig) == ["unavailable"])
    }

    /// 1. The bound itself: a started child whose ack deadline is far off is refused at the bound, killed and
    /// announced once, as at its own deadline (`timeout`).
    @Test func theBoundRefusesAndAnnouncesOnce() async throws {
        let rig = try await DuckRig(script: Confirm.neverAcked, clips: AmbientDuckModeTests.clips, ackDeadline: 30,
                                    confirmTimeout: 0.5)
        defer { rig.close() }
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        let settled = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true timeout playback=idle " + Self.unavailable])
        #expect(rig.details("ambient_privacy_start") == ["outcome=refused reason=unacknowledged"])
        #expect(!settled.contains { $0.contains("confirmprivacyon") })
    }

    /// 2a. A draining old child (its stream ended; a v2 that never acks) beside a new acking child: the old one drops
    /// out, and the privacy-on clip plays once.
    @Test func aDrainingOldChildDoesNotVetoTheEntry() async throws {
        let first = AmbientPrivacyEntryTests.fixture(saying: "", advertises: true, version: 2)
            .replacingOccurrences(of: FakeRightyo.ackingTail,
                                  with: FakeRightyo.acksMayFollow + "\n/bin/cat > /dev/null\n/bin/sleep 3\n")
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(first, AmbientDuckReloadTests.entry),
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_started").count == 1 })
        #expect(await AmbientDuckReloadTests.firstLaunched(rig))
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        let second = UUID()
        try await recipientSocketSend(audio(second, 0), on: rig.socket)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        #expect(rig.env.router.liveRuns == 2)
        let settled = await rig.settledEvents()
        try await recipientSocketSend(audio(second, 1, final: true), on: rig.socket)
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle " + Self.privacyOn])
        #expect(!settled.contains { $0.contains("unavailable") })
    }

    /// 2b. The only child exits between the write and the ack: the entry says `unavailable` once (`ended`).
    @Test func aChildThatExitsBeforeItsAckIsAnnouncedOnce() async throws {
        let script = AmbientPrivacyEventTests.enterThen([])
            .replacingOccurrences(of: FakeRightyo.ackingTail, with: "IFS= read -r ctl <&3\nexit 3\n")
        let rig = try await DuckRig(script: script, clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        let settled = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true ended playback=idle " + Self.unavailable])
        #expect(!settled.contains { $0.contains("confirmprivacyon") })
    }

    /// 3. A re-entry after the only child was refused (privacy still on, nothing proved): never "privacy on" after
    /// "unavailable"; the re-entry says `unavailable` itself.
    @Test func aReEntryAfterARefusalNeverSaysPrivacyOn() async throws {
        let rig = try await DuckRig(script: Confirm.neverAcked, clips: AmbientDuckModeTests.clips, ackDeadline: 0.3)
        defer { rig.close() }
        #expect(await eventually { Self.said(rig) == ["unavailable"] })
        let connection = try #require(rig.connection())
        rig.env.router.voiceDuck(on: connection, listener: rig.env.listener)(.enter)
        #expect(await eventually { Self.said(rig).count == 2 })
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(Self.said(rig) == ["unavailable", "unavailable"])
        #expect(rig.details("ambient_duck_confirmed").last?.hasPrefix("on=true ") == true)
    }

    /// 3. The same with a child whose on-write failed (it closed its control input): the entry and a re-entry while
    /// privacy is on each say `unavailable`, never "privacy on" (`refused`).
    @Test func aFailedOnWriteNeverSaysPrivacyOn() async throws {
        let script = """
        \(AmbientPrivacyEntryTests.startPrivatePrelude)
        /bin/sleep 0.6
        exec 3<&-
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(FakeRightyo.duckV3)
        /bin/cat > /dev/null
        """
        let rig = try await DuckRig(script: script, clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.connection() != nil })
        let connection = try #require(rig.connection())
        rig.env.router.ambientPrivacy(true, connection: connection)
        #expect(await eventually { Self.said(rig) == ["unavailable"] })
        rig.env.router.voiceDuck(on: connection, listener: rig.env.listener)(.enter)
        #expect(await eventually { Self.said(rig).count == 2 })
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == [
            "on=true reason=device refused playback=idle " + Self.unavailable,
            "on=true refused playback=idle " + Self.unavailable
        ])
    }

    /// 4. A child a reload swapped out acks before its EOF: the answer still waits for its successor, so no clip plays
    /// until the successor confirms its private start; then "privacy on", once.
    @Test func aReplacedChildsAckDoesNotAnswerForItsSuccessor() async throws {
        let first = AmbientDuckReloadTests.entry
            .replacingOccurrences(of: FakeRightyo.ackingTail, with: Confirm.holdAcks + FakeRightyo.ackingTail)
        let later = """
        \(AmbientPrivacyEntryTests.startPrivatePrelude)
        while [ ! -e go2 ]; do /bin/sleep 0.02; done
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(FakeRightyo.duckV3)
        \(FakeRightyo.ackingTail)
        """
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(first, later),
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        #expect(await rig.env.router.reload() == .reloaded)
        AmbientPrivacyAckGateTests.go(rig.fake)
        try await Task.sleep(for: .milliseconds(600))
        #expect(rig.details("ambient_duck_confirmed").isEmpty)
        FileManager.default.createFile(atPath: rig.fake.directory.appendingPathComponent("go2").path, contents: nil)
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == ["on=true playback=idle " + Self.privacyOn])
    }

    /// 5. On a switch that is not kept, the reply stop reaches the device before the unavailable clip.
    @Test func theStopComesBeforeTheUnavailableClip() async throws {
        let rig = try await DuckRig(script: Confirm.heldSwitch(acks: false), clips: AmbientDuckModeTests.clips,
                                    capabilities: [DuckMode.capability, PlaybackStop.capability], ackDeadline: 0.3)
        defer { rig.close() }
        let statusOff = AmbientPrivacySwitchTests.statusOff
        #expect(await eventually { rig.details("ambient_duck_confirmed") == [statusOff] })
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        let (before, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "unavailable")
        #expect(words == "I can't listen privately right now.")
        #expect(before.contains(.control(.stopPlayback)))
        _ = await rig.settledEvents()
        await rig.finish()
        #expect(rig.details("ambient_duck_confirmed") == [
            statusOff, "on=true reason=device unacknowledged playback=stopped " + Self.unavailable
        ])
    }
}
#endif
