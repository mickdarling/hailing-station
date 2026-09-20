import Testing
@testable import HailDaemonKit

@Suite struct LockdownStateTests {
    @Test func engagementProducesATransition() {
        var state = LockdownState()

        #expect(state.engage(reason: "manual panic") == LockdownTransition(on: true, reason: "manual panic"))
        #expect(state.isOn)
        #expect(state.reason == "manual panic")
    }

    @Test func repeatedTransitionsAreIdempotentAndKeepTheFirstReason() {
        var state = LockdownState()

        _ = state.engage(reason: "five failed handshakes")
        #expect(state.engage(reason: "later failure") == nil)
        #expect(state.reason == "five failed handshakes")
    }

    @Test func blankReasonsStillEngageWithACanonicalReason() {
        var state = LockdownState()

        #expect(
            state.engage(reason: " \t\n")
                == LockdownTransition(on: true, reason: LockdownState.unspecifiedReason)
        )
        #expect(state.isOn)
        #expect(state.reason == LockdownState.unspecifiedReason)
    }
}
