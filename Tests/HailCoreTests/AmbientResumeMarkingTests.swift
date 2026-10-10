import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #373: an automatic restart says `resume` on its first segment only, and a host's "moved" answer to it shows
/// where listening went instead of an error.
@MainActor
@Suite struct AmbientResumeMarkingTests {
    typealias Harness = AmbientListeningRecoveryTests.Harness

    @Test func onlyARestartedStreamsFirstSegmentSaysResume() async throws {
        let harness = Harness()
        harness.failingStreams = 1
        await harness.controller.turnOn(for: try binding())

        try await harness.feed { harness.sent.count >= 3 }
        #expect(harness.streams.count == 2)
        let first = harness.offered.filter { $0.streamID == harness.streams[0] }
        let restarted = harness.offered.filter { $0.streamID == harness.streams[1] }
        // The stream the user asked for never says resume; the restart says it on sequence 0 and nowhere else.
        #expect(first.allSatisfy { !$0.isResume })
        #expect(restarted.first?.sequence == 0)
        #expect(restarted.first?.isResume == true)
        #expect(restarted.dropFirst().allSatisfy { !$0.isResume })
        await harness.controller.turnOff()
    }

    @Test func aRestartRefusedAsMovedShowsWhereListeningWentWithoutAnAlert() async throws {
        let harness = Harness()
        harness.failingStreams = 2
        harness.refusals[1] = HostConnectionFailure.remote("not_allowed: ambient moved to pad")
        await harness.controller.turnOn(for: try binding())

        try await harness.feed { !harness.controller.isOn }
        #expect(harness.delays == [.seconds(1)])
        #expect(harness.controller.handoff == .movedAway(to: "pad"))
        #expect(harness.unexpectedStops.isEmpty)
        #expect(!harness.controller.isListening)
    }
}
