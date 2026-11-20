#if os(macOS)
import Foundation
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

private final class UpdateAudioCompletionHold: Sendable {
    private struct State {
        var sends = 0
        var completion: (@Sendable (NWError?) -> Void)?
    }
    private let state = Mutex(State())
    var isHeld: Bool { state.withLock { $0.completion != nil } }
    var sends: Int { state.withLock { $0.sends } }
    func send(_ complete: @escaping @Sendable (NWError?) -> Void) {
        let held = state.withLock { state in
            state.sends += 1
            guard state.sends == 2 else { return false }
            state.completion = complete
            return true
        }
        if !held { complete(nil) }
    }
    func release() {
        let complete = state.withLock { state in
            defer { state.completion = nil }
            return state.completion
        }
        complete?(nil)
    }
}

private struct HeldCompletionSpeech: SessionUpdateSpeechRendering {
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        try await publish(Data(repeating: 0, count: 480), true)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionUpdateAudioAdmissionTests {
    @Test func admissionInvalidatesCoalescingBeforeTransportCompletion() async throws {
        let hold = UpdateAudioCompletionHold()
        let rig = try await SessionUpdateListenerRig.make(audio: true, send: { hold.send($0) })
        defer { hold.release() }
        let now = ContinuousClock.now
        #expect(await !rig.session.stopReplyPlayback(voiceStopAt: now).coalesced)
        let revision = await rig.session.replyFlightRevision
        await rig.listener.configureSessionUpdateSpeech(HeldCompletionSpeech())
        #expect(await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
            priority: .action, text: "Synthetic finished")).outcome == .delivered)
        let held = await eventually { hold.isHeld }
        #expect(held)
        // Reading the actor waits for its synchronous enqueue turn, while the transport result stays held.
        #expect(await rig.session.replyFlightRevision == revision &+ 1)
        #expect(await !rig.session.stopReplyPlayback(voiceStopAt: now + .milliseconds(200)).coalesced)
        #expect(hold.isHeld && hold.sends == 2)
        hold.release()
        let fence = await rig.listener.sessionUpdateFence
        await fence.joinSpeech()
        await rig.listener.stop()
    }
}
#endif
