import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #287: a host-ended stream restarts on the same microphone, a few times at most, and every stop the user did
/// not ask for is reported so the app can notify.
@MainActor
@Suite struct AmbientListeningRecoveryTests {
    static let idleEnded = HostConnectionFailure.remote(
        "malformed: ambient stream must be new and start at sequence 0"
    )

    @MainActor
    final class Harness {
        let capture = FakeAudioCapture()
        var released = 0
        /// Every segment of the first `failingStreams` stream identities is refused with `refusal`.
        var failingStreams = 0
        var refusal: any Error = AmbientListeningRecoveryTests.idleEnded
        /// Per stream index, a refusal that replaces `refusal` (#373).
        var refusals: [Int: any Error] = [:]
        var streams: [UUID] = []
        var sent: [AudioPayload] = []
        /// Every segment offered to the host, refused or not.
        var offered: [AudioPayload] = []
        var delays: [Duration] = []
        var unexpectedStops: [String] = []
        var holdsBackoff = false
        lazy var controller: AmbientListeningController = {
            let controller = AmbientListeningController(
                requestPermission: { true },
                makeStreamer: { [unowned self] send in AmbientAudioStreamer(capture: capture, send: send) },
                releaseSession: { [unowned self] in released += 1 },
                sleep: { [unowned self] delay in try await backoff(delay) },
                send: { [unowned self] payload, _ in try await record(payload) }
            )
            controller.onUnexpectedStop = { [unowned self] in unexpectedStops.append($0) }
            return controller
        }()

        func record(_ payload: AudioPayload) throws {
            guard let stream = payload.streamID else { return }
            if !streams.contains(stream) { streams.append(stream) }
            offered.append(payload)
            if let index = streams.firstIndex(of: stream), index < failingStreams { throw refusals[index] ?? refusal }
            sent.append(payload)
        }

        func backoff(_ delay: Duration) async throws {
            delays.append(delay)
            while holdsBackoff { try await Task.sleep(for: .milliseconds(5)) }
        }

        /// Yields microphone audio until `done` holds, as a live capture would.
        func feed(until done: @MainActor () -> Bool) async throws {
            for index in 0..<400 where !done() {
                try capture.yield(sineBuffer(offset: index * 4_800))
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(done())
        }
    }

    @Test func aHostEndedStreamContinuesOnAFreshStreamFromSequenceZero() async throws {
        let harness = Harness()
        harness.failingStreams = 1
        await harness.controller.turnOn(for: try binding())

        try await harness.feed { harness.sent.count >= 3 }
        #expect(harness.controller.isOn)
        #expect(harness.controller.isListening)
        #expect(harness.streams.count == 2)
        #expect(harness.sent.allSatisfy { $0.streamID == harness.streams[1] })
        #expect(harness.sent.first?.sequence == 0)
        #expect(harness.delays == [.seconds(1)])
        #expect(harness.capture.startCount == 1)
        #expect(harness.capture.stopCount == 0)
        #expect(harness.unexpectedStops.isEmpty)
    }

    @Test func retriesStopAfterThreeAndTheStopIsReported() async throws {
        let harness = Harness()
        harness.failingStreams = 10
        await harness.controller.turnOn(for: try binding())

        try await harness.feed { !harness.controller.isOn }
        #expect(harness.delays == [.seconds(1), .seconds(3), .seconds(10)])
        #expect(harness.streams.count == 4)
        #expect(harness.controller.stopReason?.contains("Gave up after 3 restarts.") == true)
        #expect(harness.unexpectedStops == [harness.controller.stopReason])
        #expect(harness.released == 1)
    }

    @Test func aFinalRefusalStopsAtOnceAndIsReported() async throws {
        let harness = Harness()
        harness.failingStreams = 1
        harness.refusal = HostConnectionFailure.remote("not_allowed: ambient busy")
        await harness.controller.turnOn(for: try binding())

        try await harness.feed { !harness.controller.isOn }
        #expect(harness.delays.isEmpty)
        #expect(harness.unexpectedStops.count == 1)
        #expect(harness.unexpectedStops.first?.contains("ambient busy") == true)
    }

    @Test func turningOffDuringABackoffDoesNotWaitAndIsNotReported() async throws {
        let harness = Harness()
        harness.failingStreams = 1
        harness.holdsBackoff = true
        await harness.controller.turnOn(for: try binding())

        try await harness.feed { !harness.delays.isEmpty }
        await harness.controller.turnOff()
        #expect(!harness.controller.isOn)
        #expect(harness.controller.stopReason == nil)
        #expect(harness.unexpectedStops.isEmpty)
        #expect(harness.released == 1)
        #expect(harness.streams.count == 1)
    }

    @Test func losingTheDestinationIsReportedButTurningOffIsNot() async throws {
        let harness = Harness()
        await harness.controller.turnOn(for: try binding())
        await harness.controller.destinationLost()
        #expect(!harness.controller.isOn)
        #expect(harness.unexpectedStops.count == 1)
        #expect(harness.unexpectedStops.first?.contains("went away") == true)
        #expect(harness.released == 1)

        await harness.controller.turnOn(for: try binding())
        await harness.controller.turnOff()
        await harness.controller.destinationLost()
        #expect(harness.unexpectedStops.count == 1)
    }

    @Test func onlyHostEndedStreamsAreTransient() {
        let transient = [
            "malformed: ambient stream must be new and start at sequence 0",
            "malformed: ambient sequence must increase",
            "not_allowed: ambient stopped: listener exited",
            "rate_limited: ambient rate exceeded"
        ]
        let final = [
            "not_allowed: ambient busy", "not_allowed: ambient target is not selected",
            "not_allowed: ambient unavailable: no listener", "malformed: ambient segment shape"
        ]
        for message in transient {
            #expect(AmbientListeningController.isTransient(HostConnectionFailure.remote(message)))
        }
        for message in final {
            #expect(!AmbientListeningController.isTransient(HostConnectionFailure.remote(message)))
        }
        #expect(!AmbientListeningController.isTransient(HostConnectionFailure.notReady))
    }
}
