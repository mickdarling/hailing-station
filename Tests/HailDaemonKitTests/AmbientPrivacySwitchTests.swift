#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The app's privacy switch (#735 S-6, `set_privacy`): it turns privacy (internally duck) on through the owner's entry
/// path and off through the exit path, both with reason `device`, for the sending connection's own ambient stream
/// only, and is answered only by the `duck_mode` notice. A switch to the state already held, or for an arming that has
/// since changed, does nothing at all. Advertised and admitted only with ambient listening. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacySwitchTests {
    /// `started` (naming Rightyo, `duck` v3), then a `privacy` status event, which the host answers with a log line
    /// only, so a test knows the child's `started` was read. With `request`, the child then waits until the host wrote
    /// it a duck line (when `waitForPrivacy`) and says the owner's formed request. Then `stopped` at the end of audio.
    static func script(request: Bool = false, waitForPrivacy: Bool = false) -> String {
        let started = #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "phase": "started"/'"#
            + AmbientPrivacyEventTests.duck(3)
        let wait = waitForPrivacy ? "while ! /usr/bin/grep -q duck control.txt; do /bin/sleep 0.05; done\n" : ""
        // The fixture's turns and request, each one sequence later for the status event; `stopped` follows the last.
        let later = (2...6).reversed().map { #" -e 's/"sequence": \#($0),/"sequence": \#($0 + 1),/'"# }.joined()
        let said = request ? wait + #"/usr/bin/sed -n -e '2,6p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g""#
            + later + "\n" : ""
        return """
        \(FakeRightyo.ackingControl())
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \(started)
        \(AmbientPrivacyEventTests.line("status", sequence: 2, at: 0))
        \(said)\(FakeRightyo.ackingTail)
        """
    }

    static let statusOff = "status on=false confirm=unreported"

    /// A rig whose child has started (its status answered) and is waiting.
    static func startedRig(request: Bool = false, waitForPrivacy: Bool = false,
                           capabilities: [String] = [DuckMode.capability, PlaybackStop.capability]) async throws
        -> DuckRig {
        let rig = try await DuckRig(script: script(request: request, waitForPrivacy: waitForPrivacy),
                                    clips: AmbientDuckModeTests.clips, capabilities: capabilities)
        #expect(await eventually { rig.details("ambient_duck_confirmed") == [statusOff] })
        return rig
    }

    static func send(_ on: Bool, on socket: URLSessionWebSocketTask) async throws {
        try await recipientSocketSend(sessionFrame(payload: .control(.setPrivacy(on: on))), on: socket)
    }

    /// Every payload up to and including the first text frame (a confirmation's words).
    static func untilWords(_ socket: URLSessionWebSocketTask, step: String) async throws -> ([FramePayload], String?) {
        var payloads: [FramePayload] = []
        for _ in 0..<16 {
            let payload = try await receiveFrame(on: socket, step: step).payload
            if case .text(let text) = payload { return (payloads, text.text) }
            payloads.append(payload)
        }
        return (payloads, nil)
    }

    /// Sends a ping and returns every payload before the pong: whatever the host sent back meanwhile.
    static func untilPong(_ socket: URLSessionWebSocketTask, step: String,
                          within: Duration = .seconds(15)) async throws -> [FramePayload] {
        let deadline = ContinuousClock.now + within
        let nonce = UUID().uuidString
        try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket, within: within)
        var payloads: [FramePayload] = []
        for _ in 0..<32 {
            let payload = try await receiveFrame(on: socket, step: step,
                                                 within: ContinuousClock.now.duration(to: deadline)).payload
            if payload == .control(.pong(nonce: nonce)) { return payloads }
            payloads.append(payload)
        }
        Issue.record("no pong at \(step)")
        return payloads
    }

    /// On: a reply playing is stopped, the device is told on with reason `device`, the child is written private and
    /// only the privacy-on clip plays. Off: the device is told off with reason `device` and "Recording again." plays.
    /// No reply frame answers either switch.
    @Test func theSwitchTurnsPrivacyOnThenOffWithReasonDevice() async throws {
        let rig = try await Self.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        try await Self.send(true, on: rig.socket)
        let (entry, onWords) = try await Self.untilWords(rig.socket, step: "privacy on")
        #expect(onWords == "Privacy on. I'm only listening for my name.")
        #expect(entry.contains(.control(.stopPlayback)))
        #expect(entry.contains { if case .control(.duckMode(true, "device", nil)) = $0 { true } else { false } })
        #expect(entry.allSatisfy { if case .control(.error) = $0 { false } else { true } })
        #expect(router.duckMode(connection: connection))
        try await Self.send(false, on: rig.socket)
        let (exit, offWords) = try await Self.untilWords(rig.socket, step: "privacy off")
        #expect(offWords == "Recording again.")
        #expect(exit.contains(.control(.duckMode(on: false, reason: "device"))))
        #expect(!exit.contains(.control(.stopPlayback)))
        #expect(!router.duckMode(connection: connection))
        #expect(await eventually { rig.details("ambient_duck_confirmed").count == 3 })
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=device reported=1",
                                                "on=false reason=device reported=1"])
        #expect(rig.details("ambient_duck_device") == ["on=true device=sent", "on=false device=sent"])
        #expect(rig.details("ambient_duck_confirmed") == [
            Self.statusOff, "on=true reason=device playback=stopped confirm=confirmprivacyon/0:sent",
            "on=false reason=device confirm=confirmprivacyoff/0:sent"
        ])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n{\"duck\":false}\n")
    }

    /// The switch arms the hold: while private, the owner's formed request is held back from the agent. Without the
    /// switch the same request is delivered, so the check is live.
    @Test(arguments: [true, false]) func whilePrivateTheRequestIsHeldBack(_ switched: Bool) async throws {
        let rig = try await Self.startedRig(request: true, waitForPrivacy: switched)
        defer { rig.close() }
        if switched {
            try await Self.send(true, on: rig.socket)
            #expect(await eventually { rig.details("ambient_duck_confirmed").count == 2 })
        }
        await rig.finish()
        let ended = try #require(rig.details("ambient_ended").first)
        #expect(ended.contains(switched ? "delivered=0" : "delivered=1"))
        #expect(try rig.fake.recorded("control.txt") == (switched ? "{\"duck\":true}\n" : ""))
    }

    /// A switch to the state already held does nothing at all: off while off, and on while on. Nothing is logged,
    /// written to the child, played or sent back.
    @Test func aSwitchToTheStateAlreadyHeldDoesNothing() async throws {
        let rig = try await Self.startedRig()
        defer { rig.close() }
        let before = await rig.settledEvents()
        try await Self.send(false, on: rig.socket)
        #expect(try await Self.untilPong(rig.socket, step: "off while off").isEmpty)
        #expect(await rig.settledEvents() == before)
        try await Self.send(true, on: rig.socket)
        _ = try await Self.untilWords(rig.socket, step: "privacy on")
        _ = try await Self.untilPong(rig.socket, step: "the clip's audio")
        let on = await rig.settledEvents()
        try await Self.send(true, on: rig.socket)
        #expect(try await Self.untilPong(rig.socket, step: "on while on").isEmpty)
        #expect(await rig.settledEvents() == on)
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=device reported=1"])
        #expect(try rig.fake.recorded("control.txt") == "{\"duck\":true}\n")
    }

    /// Only the own connection: the command carries no connection, and another device without the stream can neither
    /// end this one's privacy nor start it. Its on, before any stream of its own, is its own pre-arm (#904, R3).
    /// Its off ends only that.
    @Test func anotherConnectionCannotSwitchIt() async throws {
        let rig = try await Self.startedRig()
        defer { rig.close() }
        let connection = try #require(rig.connection()), router = rig.env.router
        let (session, other) = try recipientSocket(port: rig.env.port)
        defer {
            other.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: [DuckMode.capability], deviceName: "other"
        )))), on: other)
        _ = try await receiveFrame(on: other, step: "other hello")
        try await Self.send(true, on: other)
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: true, reason: "device"), on: other, step: "other on")
        #expect(!router.duckMode(connection: connection))
        try await Self.send(true, on: rig.socket)
        _ = try await Self.untilWords(rig.socket, step: "privacy on")
        try await Self.send(false, on: other)
        try await AmbientPrivacyPreArmTests.until(.duckMode(on: false, reason: "device"), on: other, step: "other off",
                                                invariant: { router.duckMode(connection: connection) },
                                                invariantDescription: "rig connection must stay private")
        #expect(router.duckMode(connection: connection))
        await rig.finish()
        #expect(rig.details("ambient_duck") == ["on=true reason=device reported=1",
                                                "on=false reason=device reported=0"])
    }
}
#endif
