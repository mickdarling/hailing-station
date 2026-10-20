#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #612: the device whose stream turned media mode on is told so, with its reason and expiry, and told again when it
/// turns off; a device that did not advertise `media_mode` is never sent the command. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientMediaModeDeviceTests {
    private func run(capabilities: [String], expectFrames: Bool) async throws -> [String] {
        let fake = try FakeRightyo("/bin/cat <&3 > control.txt &\n"
            + AmbientWiringVoiceMuteTests.fixture(saying: "Rightyo, media mode."))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), replyControl: true, mediaTimeout: 0.5,
            onEvent: { event in
                if event.event == "ambient_media_device" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let (session, socket) = try recipientSocket(port: env.port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: "test"
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
        let stream = UUID()
        let before = Int64(Date().timeIntervalSince1970 * 1_000)
        try await recipientSocketSend(audio(stream, 0), on: socket)
        if expectFrames { try await expectOnThenOff(on: socket, after: before) }
        #expect(await eventually { details.withLock { $0.count == 2 } })
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        return details.withLock { $0 }
    }

    private func expectOnThenOff(on socket: URLSessionWebSocketTask, after before: Int64) async throws {
        let on = try await receiveFrame(on: socket, step: "media mode on")
        guard case .control(.mediaMode(true, "voice", let expires?)) = on.payload else {
            Issue.record("expected media_mode on, got \(on.payload)")
            return
        }
        // About the configured half second after the change, never in the past.
        #expect(expires >= before && expires <= Int64(Date().timeIntervalSince1970 * 1_000) + 1_000)
        let off = try await receiveFrame(on: socket, step: "media mode off")
        #expect(off.payload == .control(.mediaMode(on: false, reason: "timeout")))
    }

    @Test func aCapableDeviceIsToldWhenMediaModeTurnsOnAndOff() async throws {
        let details = try await run(capabilities: [MediaMode.capability], expectFrames: true)
        #expect(details == ["on=true device=sent", "on=false device=sent"])
    }

    @Test func anOlderDeviceIsNeverSentTheCommand() async throws {
        let details = try await run(capabilities: [], expectFrames: false)
        #expect(details == ["on=true device=unsupported", "on=false device=unsupported"])
    }
}
#endif
