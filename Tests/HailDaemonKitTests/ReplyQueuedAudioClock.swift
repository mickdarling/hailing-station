#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
@testable import HailDaemonKit

func queuedTextCard(_ descriptor: ReplyDescriptor) -> Frame {
    Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID,
        payload: .text(TextPayload(text: "synthetic response", reply: descriptor, metadata: "synthetic card")))
}

final class QueuedAudioClock: Sendable {
    let origin = ContinuousClock.now
    private let offset = Mutex<Duration>(.zero)
    let deadline = Mutex<ContinuousClock.Instant?>(nil)
    let sleepEntered = VoiceStopConfirmationHold(), timer = VoiceStopConfirmationHold()
    var now: ContinuousClock.Instant { origin.advanced(by: offset.withLock { $0 }) }
    func advance(_ duration: Duration) { offset.withLock { $0 += duration } }
    func release() { timer.release() }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        self.deadline.withLock { $0 = deadline }
        sleepEntered.release()
        await timer.wait()
        try Task.checkCancellation()
    }
    func makeRig() async throws -> DeviceVoiceStopRig {
        try await ReplyAudioEnqueueTesting.$clock.withValue({ self.now }, operation: {
            try await ReplyAudioEnqueueTesting.$budgetSleep.withValue({ try await self.sleep(until: $0) }, operation: {
                try await DeviceVoiceStopRig.make()
            })
        })
    }
    func queue() -> ReplyAudioQueue {
        ReplyAudioEnqueueTesting.$budgetSleep.withValue({ try await self.sleep(until: $0) }, operation: {
            ReplyAudioQueue(now: { self.now })
        })
    }
}

/// Timeout tasks for overlapping stops may all enter before release.
final class QueuedAudioGate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard !state.open else { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
#endif
