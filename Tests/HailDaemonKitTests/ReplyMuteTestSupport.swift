#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The child blocks on a FIFO read; the writer runs off the Swift cooperative pool.
func releaseStopMuteFixture(_ fake: FakeRightyo) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        DispatchQueue.global().async {
            do {
                let writer = try FileHandle(forWritingTo: fake.directory.appendingPathComponent("release"))
                defer { try? writer.close() }
                try writer.write(contentsOf: Data("release\n".utf8))
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Recording precedes notification, so assertions observe the completed mute outcome.
final class ReplyMuteOutcome: Sendable {
    private let recorded = Mutex<[String]>([])
    let completed = VoiceStopConfirmationHold()
    let ended = VoiceStopConfirmationHold()
    var details: [String] { recorded.withLock { $0 } }

    func record(_ event: WebSocketListenerEvent) {
        if event.event == "ambient_voice_mute" {
            recorded.withLock { $0.append(event.detail ?? "") }
            completed.release()
        }
        if event.event == "ambient_ended" { ended.release() }
    }
}

struct ReplyMuteFixture {
    let fake: FakeRightyo
    let started: VoiceStopConfirmationHold

    func start(on env: AmbientWiringRig, socket: URLSessionWebSocketTask) async throws {
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        await started.wait()
        try #require(env.router.activeConnection() != nil)
        try await releaseStopMuteFixture(fake)
    }
}

/// Each notification follows the state mutation it names, including the queued privacy work.
final class ReplyMutePrivacyNotifications: Sendable {
    let started = VoiceStopConfirmationHold()
    let dropped = VoiceStopConfirmationHold()
    let released = VoiceStopConfirmationHold()
    let ended = VoiceStopConfirmationHold()

    func record(_ event: WebSocketListenerEvent) {
        if event.event == "ambient_started" { started.release() }
        if event.event == "ambient_ended" { ended.release() }
        guard event.event == "ambient_privacy_replies" else { return }
        if event.detail?.hasPrefix("dropped=") == true { dropped.release() }
        if event.detail == "released=true" { released.release() }
    }
}

func replyMuteTypedRequest(on rig: DuckRig, session: HostSession) async throws -> UUID {
    let frame = sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input")))
    try await recipientSocketSend(frame, on: rig.socket)
    // The socket processes input serially: its pong acknowledges the preceding typed dispatch and reply record.
    try await barrier(on: rig.socket, step: "typed mute request admitted")
    let contexts = await rig.env.rig.adapter.contexts
    #expect(contexts.contains { $0.utteranceID == frame.id })
    let id = try #require(contexts.first { $0.utteranceID == frame.id }).id
    #expect(await session.replyRequests[id] != nil)
    return id
}
#endif
