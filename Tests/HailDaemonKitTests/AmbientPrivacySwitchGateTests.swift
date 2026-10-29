#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The app's privacy switch (#735 S-6), continued: the token race, the way out of a child respawned start-private,
/// the fail-closed refusal by an older child, and who may send it at all. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacySwitchGateTests {
    /// The token race (H-4 F1): a device switch applies only to the arming it read. The owner's voice exit after the
    /// read makes a device off a no-op (no second off saying `device`), and so does an exit and re-entry; an on read
    /// while off does nothing once the voice has entered meanwhile.
    @Test func aSwitchForAStaleArmingDoesNothing() async throws {
        let rig = try await AmbientPrivacySwitchTests.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        let stale = try #require(router.duckArming(connection: connection))
        #expect(router.setDuck(false, connection: connection, reason: "voice") == 1)
        var before = await rig.settledEvents()
        router.switchPrivacy(false, connection: connection, armedAs: stale)
        #expect(await rig.settledEvents() == before)
        #expect(router.setDuck(true, connection: connection, reason: "voice") == 1)
        before = await rig.settledEvents()
        router.switchPrivacy(false, connection: connection, armedAs: stale)
        router.switchPrivacy(true, connection: connection, armedAs: nil)
        #expect(await rig.settledEvents() == before)
        #expect(router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=voice reported=1",
                                                "on=true reason=voice reported=1"])
        #expect(!rig.details("ambient_duck_confirmed").contains { $0.contains("reason=device") })
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n{\"duck\":true}\n")
    }

    /// The way out after a respawn (Jarvis): a child respawned while private starts private (S-2b) and never binds the
    /// owner's voiceprint, so the voice exit cannot reach it. The switch's off writes `{"duck":false}` to that child,
    /// exactly as the voice exit does, ends privacy and tells the device off with reason `device`.
    @Test func theSwitchEndsPrivacyInAChildRespawnedStartPrivate() async throws {
        let started = #"-e 's/"phase": "started"/"duck": {"version": 3'"$PRIV"'}, "phase": "started"/'"#
        let later = """
        echo "$*" >> argv.txt
        \(AmbientPrivacyEntryTests.startPrivatePrelude)
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(started)
        \(AmbientPrivacyEventTests.line("status", sequence: 2, at: 0))
        \(FakeRightyo.ackingTail)
        """
        let rig = try await DuckRig(script: AmbientDuckReloadTests.staged(AmbientDuckReloadTests.entry, later),
                                    clips: AmbientDuckModeTests.clips, capabilities: [DuckMode.capability])
        defer { rig.close() }
        _ = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "voice entry")
        let connection = try #require(rig.connection()), router = rig.env.router
        #expect(await router.reload() == .reloaded)
        let status = "status on=true confirm=confirmprivacystatus/0:sent"
        #expect(await eventually { rig.details("ambient_duck_confirmed").contains(status) })
        #expect(try rig.fake.recorded("argv.txt").hasSuffix("--start-private\n"))
        #expect(rig.details("ambient_privacy_start").isEmpty)
        #expect(router.duckMode(connection: connection))
        _ = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "earlier clips")
        try await AmbientPrivacySwitchTests.send(false, on: rig.socket)
        let (exit, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "privacy off")
        #expect(words == "Recording again.")
        #expect(exit.contains(.control(.duckMode(on: false, reason: "device"))))
        #expect(!router.duckMode(connection: connection))
        #expect(await eventually {
            (try? rig.fake.recorded("control.txt")) == "{\"duck\":true}\n{\"duck\":false}\n"
        })
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=voice reported=1", "on=false reason=device reported=1"])
    }

    /// Jarvis: after the host stopped the stream while private (no child could keep privacy), the switch still turns
    /// privacy off for the connection, with the device notice; on stays refused without a stream.
    @Test func offWorksAfterTheStreamEndedOnDoesNot() async throws {
        let rig = try await AmbientPrivacySwitchTests.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        _ = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "privacy on")
        try await recipientSocketSend(audio(rig.stream, 1, final: true), on: rig.socket)
        #expect(await eventually { rig.details("ambient_ended").count == 1 })
        _ = try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "stream ended")
        #expect(router.duckMode(connection: connection))
        try await AmbientPrivacySwitchTests.send(false, on: rig.socket)
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: false, reason: "device"), on: rig.socket, step: "off")
        #expect(!router.duckMode(connection: connection))
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        #expect(try await AmbientPrivacySwitchTests.untilPong(rig.socket, step: "on without a stream").isEmpty)
        #expect(!router.duckMode(connection: connection))
        await rig.settle()
        await rig.env.listener.stop(reason: "synthetic test complete")
        #expect(rig.details("ambient_duck") == ["on=true reason=device reported=1",
                                                "on=false reason=device reported=0"])
    }

    /// A v1 child cannot take privacy: the switch fails closed. Privacy stays off, the device is told off (reason
    /// `device`) so its switch settles on not private, "Nothing was sent." plays, and playback is left alone.
    @Test func aVersionOneChildRefusesTheSwitch() async throws {
        let rig = try await DuckRig(saying: "Synthetic words.", advertises: true, version: 1,
                                    clips: AmbientDuckModeTests.clips,
                                    capabilities: [DuckMode.capability, PlaybackStop.capability])
        defer { rig.close() }
        #expect(await eventually { !rig.details("ambient_acknowledged").isEmpty })
        let connection = try #require(rig.connection())
        try await AmbientPrivacySwitchTests.send(true, on: rig.socket)
        let (payloads, words) = try await AmbientPrivacySwitchTests.untilWords(rig.socket, step: "refused")
        #expect(words == "Nothing was sent.")
        #expect(payloads.contains(.control(.duckMode(on: false, reason: "device"))))
        #expect(!payloads.contains(.control(.stopPlayback)))
        #expect(!rig.env.router.duckMode(connection: connection))
        #expect(await eventually { !rig.details("ambient_duck_confirmed").isEmpty })
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=device reported=0 refused=unsupported"])
        #expect(rig.details("ambient_duck_confirmed") == [
            "on=true reason=device refused=unsupported_version device=sent confirm=confirmnotsent/0:sent"
        ])
        #expect(try rig.fake.recorded("control.txt") == "")
    }

    /// Without ambient listening the host neither advertises nor admits it, like `ambient_input`; the probe refuses it.
    @Test(arguments: [true, false]) func withoutAGateOrOnTheProbeItIsRefused(_ on: Bool) async {
        let frame = Frame(timestamp: 1, source: "terminal", payload: .control(.setPrivacy(on: on)))
        let plain = PersonalTerminalAuthorizer()
        #expect(!plain.capabilities.contains(DuckMode.privacySwitchCapability))
        #expect(await plain.authorize(frame) == .deny)
        let probe = ConnectionProbeAuthorizer()
        #expect(!probe.capabilities.contains(DuckMode.privacySwitchCapability))
        #expect(await probe.authorize(frame) == .deny)
        let gated = PersonalTerminalAuthorizer(
            ambientAudio: AmbientAudioGate(target: "tmux:a", sink: SwitchSink(), sweepInterval: nil)
        )
        #expect(gated.capabilities.contains(DuckMode.privacySwitchCapability))
        #expect(await gated.authorize(frame) == .allow)
    }

    /// The gate hands an on only for the connection holding the active stream, and an off for the sending connection
    /// itself, listening or not, exactly as given; a sink without privacy mode ignores it.
    @Test func theGateHandsOnOnlyTheStreamHoldersOnAndAnyOwnOff() async {
        let sink = SwitchSink(), (holder, other) = (UUID(), UUID())
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        await gate.setPrivacy(true, connection: holder)
        #expect(sink.switches.withLock { $0 }.isEmpty)
        let segment = ambientSegment(stream: UUID(), sequence: 0)
        #expect(await gate.admit(segment, frameTarget: "tmux:a", selectedTarget: "tmux:a", connection: holder) == nil)
        await gate.setPrivacy(true, connection: other)
        await gate.setPrivacy(true, connection: holder)
        await gate.setPrivacy(false, connection: other)
        #expect(sink.switches.withLock { $0 } == ["true \(holder)", "false \(other)"])
        struct Plain: AmbientAudioSink { func ambientAudio(_ event: AmbientAudioEvent) {} }
        Plain().ambientPrivacy(true, connection: holder)
    }
}

/// Records each privacy switch it is handed, as `on connection`.
private final class SwitchSink: AmbientAudioSink {
    let switches = Mutex<[String]>([])
    func ambientAudio(_ event: AmbientAudioEvent) {}
    func ambientPrivacy(_ on: Bool, connection: UUID) { switches.withLock { $0.append("\(on) \(connection)") } }
}
#endif
