#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The listener rig, kept outside the suite's body so it stays within the type-length limit.
extension AmbientWiringVoiceMuteTests {
    /// One ambient stream whose request says `saying`, with confirmation clips loaded, from a device advertising
    /// `capabilities`; waits for the `ambient_voice_mute` line, runs `check`, then returns every such detail.
    func run(
        saying words: String, capabilities: [String], check: (URLSessionWebSocketTask) async throws -> Void
    ) async throws -> [String] {
        let fake = try FakeRightyo(Self.fixture(saying: words))
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let details = Mutex<[String]>([]), diagnosis = Mutex<[String]>([])
        let library = AmbientAckLibrary(clips: [
            "confirmstopped": [AmbientWiringStopConfirmationTests.stopped], "confirmmuted": [Self.muted],
            "confirmunmuted": [Self.unmuted]
        ])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: library,
            onEvent: { event in
                if ["ambient_refused", "ambient_ended"].contains(event.event) {
                    diagnosis.withLock { if $0.count < 16 { $0.append("\(event.event): \(event.detail ?? "")") } }
                }
                if event.event == "ambient_voice_mute" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        do {
            let (session, socket) = try recipientSocket(port: env.port)
            defer {
                socket.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
            }
            try await greetMuteSocket(socket, capabilities: capabilities)
            let stream = UUID()
            try await recipientSocketSend(audio(stream, 0), on: socket)
            try #require(await eventually { details.withLock { !$0.isEmpty } },
                         "No voice-mute outcome; authored lifecycle: \(diagnosis.withLock { $0 })")
            try await check(socket)
            try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
            await env.router.settle()
        } catch {
            await env.listener.stop(reason: "synthetic test failure")
            throw error
        }
        await env.listener.stop(reason: "synthetic test complete")
        return details.withLock { $0 }
    }
    private func greetMuteSocket(_ socket: URLSessionWebSocketTask, capabilities: [String]) async throws {
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: "test"
        )))), on: socket)
        _ = try await recipientSocketReceive(on: socket)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))),
                                      on: socket)
        try await recipientSocketBarrier(on: socket)
    }
}
#endif
