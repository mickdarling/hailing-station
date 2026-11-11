import Foundation
import Testing
@testable import HailCore

/// The existing device controller owns retries for the host's fixed session-change ending.
@MainActor
@Suite struct AmbientSessionChangeRecoveryTests {
    private static let changed = HostConnectionFailure.remote("not_allowed: ambient stopped: target session changed")

    @Test func sessionChangeRestartsWithANewIdentityAtSequenceZero() async throws {
        let harness = AmbientListeningRecoveryTests.Harness()
        harness.failingStreams = 1
        harness.refusal = Self.changed
        await harness.controller.turnOn(for: try binding())
        try await harness.feed { harness.sent.count >= 3 }
        #expect(harness.streams.count == 2)
        #expect(harness.delays == [.seconds(1)])
        #expect(harness.sent.allSatisfy { $0.streamID == harness.streams[1] })
        #expect(harness.sent.first?.sequence == 0)
        #expect(harness.sent.first?.isResume == true)
        #expect(harness.controller.isListening)
        await harness.controller.turnOff()
    }

    @Test func persistentSessionChangeExhaustsTheExistingThreeRetries() async throws {
        let harness = AmbientListeningRecoveryTests.Harness()
        harness.failingStreams = 10
        harness.refusal = Self.changed
        await harness.controller.turnOn(for: try binding())
        try await harness.feed { !harness.controller.isOn && harness.released > 0 }
        #expect(harness.delays == [.seconds(1), .seconds(3), .seconds(10)])
        #expect(harness.streams.count == 4)
        #expect(Set(harness.streams).count == 4)
        for stream in harness.streams {
            #expect(harness.offered.first { $0.streamID == stream }?.sequence == 0)
        }
        #expect(harness.controller.stopReason?.contains("Gave up after 3 restarts.") == true)
        #expect(harness.unexpectedStops == [harness.controller.stopReason])
        #expect(harness.released == 1)
    }
}
