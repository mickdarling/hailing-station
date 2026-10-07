import Testing
@testable import HailDaemonKit

@Suite struct TmuxSubmitConfirmationTests {
    private static let binding = "$2@1758230001/%2:502"
    private static let fast = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(2),
        settleLimit: .seconds(5), confirmLimit: .milliseconds(60)
    )

    private func adapter(_ pane: ScriptedPane, timing: TmuxSubmitTiming = fast) -> SubmitHarness {
        SubmitHarness(pane, timing: timing)
    }

    @Test func anAcceptedEnterIsSentOnceAfterABaselineAndASettledCapture() async throws {
        let pane = ScriptedPane()
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        let calls = await harness.runner.calls
        let capture = ["tmux", "capture-pane", "-p", "-t", "%2"]
        let typing = try #require(calls.firstIndex { $0.contains("-l") })
        #expect(calls[..<typing].contains(capture), "baseline taken before any text")
        #expect(try await harness.capturesBeforeFirstEnter() == 3)
        #expect(harness.log.all == [.confirmed])
    }

    @Test func theEnterWaitsUntilThePaneStopsChanging() async throws {
        let pane = ScriptedPane(settling: 4)
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        // Baseline, four frames still being drawn, then two identical captures of the typed text.
        #expect(try await harness.capturesBeforeFirstEnter() == 7)
        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }

    @Test func aStalePrePasteScreenIsNotTakenAsSettled() async throws {
        // The busy TUI keeps showing the screen from before the text for three captures, then draws it; the
        // first Enter is swallowed. Settling on the stale screen would see the later redraw as a reaction.
        let pane = ScriptedPane(stale: 3, swallowed: 1)
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(try await harness.capturesBeforeFirstEnter() == 6)
        #expect(await harness.keys == ["synthetic input", "Enter", "Enter"])
        #expect(harness.log.all == [.retried])
    }

    @Test func aScreenThatNeverLeavesTheBaselineIsUnverifiable() async throws {
        let pane = ScriptedPane(stale: .max, swallowed: 1)
        let harness = adapter(pane, timing: TmuxSubmitTiming(
            settleFloor: .milliseconds(1), pollInterval: .milliseconds(2),
            settleLimit: .milliseconds(40), confirmLimit: .milliseconds(60)
        ))

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        let calls = await harness.runner.calls
        #expect(calls.last?.last == "Enter", "no confirmation captures after the Enter")
        #expect(harness.log.all == [.unverifiable])
    }

    @Test func aScreenThatNeverStopsChangingGetsOneEnterAndNoRetry() async throws {
        let pane = ScriptedPane(settling: .max, swallowed: 1)
        let harness = adapter(pane, timing: TmuxSubmitTiming(
            settleFloor: .milliseconds(1), pollInterval: .milliseconds(2),
            settleLimit: .milliseconds(40), confirmLimit: .milliseconds(60)
        ))

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.unsettled])
    }

    @Test func aSwallowedEnterIsRetriedOnceAfterReverifyingTheTarget() async throws {
        let pane = ScriptedPane(swallowed: 1)
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: Self.binding)

        #expect(await harness.keys == ["synthetic input", "Enter", "Enter"])
        let calls = await harness.runner.calls
        let enters = calls.indices.filter { calls[$0].last == "Enter" }
        let between = calls[enters[0]..<enters[1]]
        #expect(between.contains { $0.contains("list-sessions") }, "identity re-checked before the retry")
        #expect(between.contains { $0.contains("capture-pane") }, "the retry follows an observed unchanged pane")
        #expect(harness.log.all == [.retried])
    }

    @Test func noRetryWhenTheFirstEnterWasAccepted() async throws {
        let pane = ScriptedPane()
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        // Well past the confirm window: nothing else is sent once the pane has reacted.
        try await Task.sleep(for: .milliseconds(150))

        #expect(pane.enters == 1)
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func anEnterNeverObservedFailsAfterOneRetryAndTaintsThePane() async throws {
        let pane = ScriptedPane(swallowed: .max)
        let harness = adapter(pane)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }
        #expect(await harness.keys == ["synthetic input", "Enter", "Enter"])
        #expect(harness.log.all == [.failed])
    }

    @Test func aRebindBetweenTheEntersSendsNoSecondEnterAndTaintsThePane() async throws {
        let pane = ScriptedPane(swallowed: 1, rebindAfterEnter: true)
        let harness = adapter(pane)

        await #expect(throws: AdapterError.rebound("codex")) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: Self.binding)
        }
        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.failed])
        // The original pane comes back under the same binding: it still holds unsubmitted text.
        pane.restoreListing()
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: Self.binding)
        }
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func abandonmentDuringSettleSendsNoEnterAndTaintsThePane() async throws {
        let pane = ScriptedPane()
        let harness = adapter(pane, timing: TmuxSubmitTiming(
            settleFloor: .milliseconds(300), pollInterval: .milliseconds(2),
            settleLimit: .seconds(5), confirmLimit: .milliseconds(60)
        ))
        let delivery = Task { try await harness.adapter.deliver("synthetic input", to: "codex", binding: Self.binding) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await harness.keys.isEmpty {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(2))
        }
        delivery.cancel()
        await #expect(throws: CancellationError.self) { try await delivery.value }
        // Let the abandoned delivery finish its settle and reach the refused commit.
        try await Task.sleep(for: .milliseconds(500))

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: Self.binding)
        }
        #expect(await harness.keys == ["synthetic input"])
        #expect(harness.log.all.isEmpty)
    }

    @Test func aPaneUnreadableOnlyDuringConfirmationKeepsTheSingleEnter() async throws {
        let pane = ScriptedPane(swallowed: 1, readableAfterEnter: false)
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.unverifiable])
    }
}
