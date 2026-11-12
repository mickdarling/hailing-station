#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Deliberately attempts publication after cancellation: final admission must refuse even an uncooperative renderer.
final class HeldStopUpdateSpeech: SessionUpdateSpeechRendering {
    let hold: VoiceStopConfirmationHold
    let firstBeforeHold: Bool
    let results = Mutex<[String]>([])
    static let first = Data(repeating: 6, count: 480)
    static let last = Data(repeating: 7, count: 240)

    init(hold: VoiceStopConfirmationHold, firstBeforeHold: Bool = false) {
        self.hold = hold; self.firstBeforeHold = firstBeforeHold
    }

    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        if firstBeforeHold { try await publish(Self.first, false) }
        await hold.wait()
        results.withLock { $0.append(Task.isCancelled ? "cancelled" : "running") }
        do {
            if !firstBeforeHold { try await publish(Self.first, false) }
            try await publish(Self.last, true)
            results.withLock { $0.append("completed") }
        } catch {
            results.withLock { $0.append("refused") }
            throw error
        }
    }
}

let stopUpdateCapabilities = [PlaybackStop.capability, SessionUpdateCard.capability, SessionUpdateCard.audioCapability]

func submitStopUpdate(_ listener: WebSocketListener) async {
    let result = await listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
        priority: .action, text: "Synthetic finished", card: "Synthetic retained card"))
    #expect(result.outcome == .delivered)
}

func receiveStopUpdateCard(on socket: URLSessionWebSocketTask) async throws -> UUID {
    let frame = try await receiveFrame(on: socket, step: "retained update card")
    guard case .control(.sessionUpdate(let id, let session, let priority, let text, let card)) = frame.payload else {
        throw StopUpdateTestError.expectedCard
    }
    #expect(session == "reply" && priority == "action")
    #expect(text == "Synthetic finished" && card == "Synthetic retained card")
    return id
}

func receiveStopUpdateAudio(
    on socket: URLSessionWebSocketTask, update: UUID, sequence: Int, final: Bool
) async throws {
    let frame = try await receiveFrame(on: socket, step: "session update audio")
    guard case .audio(let audio) = frame.payload else { throw StopUpdateTestError.expectedAudio }
    #expect(audio.reply?.sessionUpdateID == update && audio.reply?.id == update)
    #expect(audio.sequence == sequence && audio.isFinal == final)
    #expect(audio.bytes == (sequence == 0 ? HeldStopUpdateSpeech.first : HeldStopUpdateSpeech.last))
}

func verifyUpdateAfterStop(_ rig: DeviceVoiceStopRig, previous: UUID) async throws {
    let hold = VoiceStopConfirmationHold()
    hold.release()
    let speech = HeldStopUpdateSpeech(hold: hold)
    await rig.env.listener.configureSessionUpdateSpeech(speech)
    await submitStopUpdate(rig.env.listener)
    let update = try await receiveStopUpdateCard(on: rig.socket)
    #expect(update != previous)
    try await receiveStopUpdateAudio(on: rig.socket, update: update, sequence: 0, final: false)
    try await receiveStopUpdateAudio(on: rig.socket, update: update, sequence: 1, final: true)
    let fence = await rig.env.listener.sessionUpdateFence
    await fence.joinSpeech()
    #expect(speech.results.withLock { $0 } == ["running", "completed"])
    try await barrier(on: rig.socket, step: "later update completed in full")
}

func makeStopMuteFixture() throws -> FakeRightyo {
    let rest = AmbientWiringVoiceMuteTests.fixture(saying: "mute", named: false)
        .replacingOccurrences(of: "-e '$d'", with: "-e '1d;$d'")
    let script = """
    /usr/bin/head -1 events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
    while [ ! -f release ]; do /bin/sleep 0.02; done
    \(rest)
    """
    let fake = try FakeRightyo(script)
    do { try fake.install(fixture: "tool-events.jsonl"); return fake } catch { fake.cleanUp(); throw error }
}

func startHeldUpdateStop(
    _ rig: DeviceVoiceStopRig, connection: UUID, snapshot: VoiceStopConfirmationHold,
    entered: VoiceStopConfirmationHold, timeout: VoiceStopConfirmationHold
) -> Task<Void, Never> {
    Task {
        await ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            await ReplyAudioEnqueueTesting.$beforeStopSnapshot.withValue({
                entered.release()
                await snapshot.wait()
            }, operation: {
                await rig.env.router.deviceVoiceStopped(connection: connection, latencyMs: nil)
            })
        })
    }
}

enum StopUpdateTestError: Error { case expectedCard, expectedAudio }
#endif
