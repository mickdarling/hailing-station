import Foundation
import Testing
@testable import HailProtocol

@Suite struct ModeSnapshotReasonTests {
    @Test func heldElsewhereIsAFixedDuckReasonAndRoundTrips() throws {
        #expect(DuckMode.reason("held_elsewhere") == "held_elsewhere")
        #expect(DuckMode.reason("Held_elsewhere") == nil)
        let frame = Frame(timestamp: 1, source: "host",
                          payload: .control(.duckMode(on: true, reason: "held_elsewhere")))
        #expect(try FrameCoding.decode(FrameCoding.encode(frame)) == frame)
    }
}
