#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct ReplyQueuedAudioPendingTests {
    @Test func captureAfterTeardownMarksNothing() async throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
        let ticket = try queue.ticket()
        queue.forget(connection)
        #expect(queue.captureStop(connection) == nil)
        try await queue.waitForStops(ticket)
        if case .sent(true) = queue.enqueue(ticket, connection: nil, target: "target", { true }) {} else {
            Issue.record("a stop attempted after teardown must capture nothing")
        }
    }

    @Test func boundedTimeoutRaisesFloorAndReleasesFirstFrame() async throws {
        #expect(ReplyAudioQueue.stopResolutionDeadline == .milliseconds(250))
        let queue = ReplyAudioQueue(), connection = UUID()
        let timeout = VoiceStopConfirmationHold(), waiting = VoiceStopConfirmationHold()
        defer { timeout.release() }
        queue.register(connection)
        let old = try queue.ticket()
        let stop = try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            try #require(queue.captureStop(connection))
        })
        let post = try queue.ticket()
        let admission = Task {
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await queue.waitForStops(old)
            })
        }
        await waiting.wait()
        try await queue.waitForStops(post)
        if case .sent(true) = queue.enqueue(post, connection: nil, target: "target", { true }) {} else {
            Issue.record("post-stop ticket must proceed before timeout")
        }
        timeout.release() // Drives the actual timeout task, without a clock sleep.
        try await admission.value
        queue.resolve(stop, targets: ["other"]) // A late snapshot cannot undo the timeout floor.
        if case .stopped = queue.enqueue(old, connection: nil, target: "target", { true }) {} else {
            Issue.record("timeout must preserve pre-stop silence globally")
        }
        if case .sent(true) = queue.enqueue(post, connection: nil, target: "target", { true }) {} else {
            Issue.record("timeout must never cover a later ticket")
        }
    }

    @Test func everyCoveringPendingStopMustResolve() async throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        queue.register(connection)
        let ticket = try queue.ticket()
        let first = try #require(queue.captureStop(connection))
        let second = try #require(queue.captureStop(connection))
        queue.resolve(first, targets: [])
        if case .pending = queue.enqueue(ticket, connection: nil, target: "target", publishing: true, {
            Issue.record("pending stop must refuse the transport closure")
            return true
        }) {} else {
            Issue.record("the second pending stop must still gate first audio")
        }
        queue.resolve(second, targets: ["target"])
        try await queue.waitForStops(ticket)
        if case .stopped = queue.enqueue(ticket, connection: nil, target: "target", { true }) {} else {
            Issue.record("admission must recheck marks after all stops resolve")
        }
    }

    @Test func failedStopBoundsAdmissionEvenWhileAnotherStopIsPending() async throws {
        let queue = ReplyAudioQueue(), connection = UUID()
        let timeouts = [VoiceStopConfirmationHold(), VoiceStopConfirmationHold()]
        queue.register(connection)
        let old = try queue.ticket()
        let stops = try timeouts.map { timeout in
            try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
                try #require(queue.captureStop(connection))
            })
        }
        defer {
            queue.resolve(stops[1], targets: [])
            for timeout in timeouts { timeout.release() }
        }
        queue.resolve(stops[0], targets: nil)
        // A floor is already definitive. New pending stops cannot keep an already-silent job waiting forever.
        try await queue.waitForStops(old)
        if case .stopped = queue.enqueue(old, connection: nil, target: "target", { true }) {} else {
            Issue.record("a known floor must skip without awaiting another pending stop")
        }
        let later = try queue.ticket()
        try await queue.waitForStops(later)
        if case .sent(true) = queue.enqueue(later, connection: nil, target: "target", { true }) {} else {
            Issue.record("post-cutoff ticket must still play with a pending stop")
        }
    }

    @Test func waitingAdmissionCanBeCancelled() async throws {
        let queue = ReplyAudioQueue(), connection = UUID(), waiting = VoiceStopConfirmationHold()
        let timeout = VoiceStopConfirmationHold()
        queue.register(connection)
        let ticket = try queue.ticket()
        let stop = try ReplyAudioEnqueueTesting.$stopTimeout.withValue({ await timeout.wait() }, operation: {
            try #require(queue.captureStop(connection))
        })
        defer { queue.resolve(stop, targets: []); timeout.release() }
        let admission = Task {
            try await ReplyAudioEnqueueTesting.$waiting.withValue({ waiting.release() }, operation: {
                try await queue.waitForStops(ticket)
            })
        }
        await waiting.wait()
        admission.cancel()
        await #expect(throws: CancellationError.self) { try await admission.value }
    }
}
#endif
