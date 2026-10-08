import Testing
@testable import HailDaemonKit

/// #83, #304: the Enter waits until the pane shows the pasted text at the cursor, and only text leaving the cursor
/// confirms it. Scripted pane only; no tmux process is spawned.
@Suite struct TmuxSubmitConfirmationTests {
    private static let binding = "$2@1758230001/%2:502"
    private static let fast = timing(settleLimit: .seconds(5))

    private static func timing(settleLimit: Duration, settleFloor: Duration = .milliseconds(1)) -> TmuxSubmitTiming {
        TmuxSubmitTiming(
            settleFloor: settleFloor, pollInterval: .milliseconds(2), quiet: .milliseconds(6),
            settleLimit: settleLimit, confirmLimit: .milliseconds(500)
        )
    }

    private func adapter(_ pane: ScriptedPane, timing: TmuxSubmitTiming = fast) -> SubmitHarness {
        SubmitHarness(pane, timing: timing)
    }

    @Test func anAcceptedEnterIsSentOnceAfterABaselineAndTheTextAtTheCursor() async throws {
        let pane = ScriptedPane()
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        let calls = await harness.runner.calls
        let filling = try #require(calls.firstIndex { $0.contains("set-buffer") })
        #expect(calls[..<filling].contains { $0.contains("capture-pane") }, "baseline taken before any text")
        // The baseline, then the typed screen held for the quiet period.
        #expect(try await harness.capturesBeforeFirstEnter() >= 3)
        #expect(harness.log.all == [.confirmed])
    }

    @Test func theEnterWaitsUntilThePaneShowsTheText() async throws {
        let pane = ScriptedPane(settling: 4)
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        // Baseline, four frames still being drawn, then the typed text held still.
        #expect(try await harness.capturesBeforeFirstEnter() >= 7)
        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }

    @Test func aStalePrePasteScreenIsNotTakenAsAccepted() async throws {
        // A busy TUI keeps showing the screen from before the text for three looks, then draws it. Only the text
        // at the cursor counts, so the stale screen never releases the Enter.
        let pane = ScriptedPane(stale: 3)
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(try await harness.capturesBeforeFirstEnter() >= 6)
        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }

    @Test func textThatNeverAppearsGetsOneEnterAnywayAndIsUnsettled() async throws {
        // The baseline already shows an earlier prompt with the same ending in the transcript, above an empty
        // input: text away from the cursor is not acceptance.
        let pane = ScriptedPane(baseline: ScriptedPane.submittedScreen, stale: .max)
        let harness = adapter(pane, timing: Self.timing(settleLimit: .milliseconds(40)))

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.unsettled])
    }

    @Test func aScreenThatNeverStopsChangingGetsOneEnterAndIsUnsettled() async throws {
        let pane = ScriptedPane(settling: .max)
        let harness = adapter(pane, timing: Self.timing(settleLimit: .milliseconds(40)))

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.unsettled])
    }

    @Test func anEnterTakenAsANewlineIsRetriedOnceAfterReverifyingTheTarget() async throws {
        // #304: a TUI that read the Enter together with text inserts a newline; the tail is still in the input,
        // with only whitespace before the cursor, and the pane changed, so the target is alive: one retry.
        let pane = ScriptedPane(afterEnter: [ScriptedPane.absorbedScreen, ScriptedPane.submittedScreen])
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: Self.binding)

        #expect(await harness.keys == ["synthetic input", "Enter", "Enter"])
        let calls = await harness.runner.calls
        let enters = calls.indices.filter { calls[$0].last == "Enter" }
        let between = calls[enters[0]..<enters[1]]
        #expect(between.contains { $0.contains("list-sessions") }, "identity re-checked before the retry")
        #expect(between.contains { $0.contains("capture-pane") }, "the retry follows text still held at the cursor")
        #expect(harness.log.all == [.retried])
    }

    @Test func aPaneThatNeverChangesAfterTheEnterGetsNoSecondEnter() async throws {
        // #304 review: a frozen TUI shows the text at the cursor, unchanged, with the Enter still queued. A second
        // Enter would join it in one read and both would become newlines, so nothing more is sent.
        let pane = ScriptedPane(afterEnter: [ScriptedPane.typedScreen])
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.unverifiable])
        // Not tainted, but the text still at the cursor refuses the next delivery until it is gone.
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("later input", to: "codex", binding: nil)
        }
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func noRetryWhenTheFirstEnterWasAccepted() async throws {
        let pane = ScriptedPane()
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        // Well past the confirm window: nothing else is sent once the text has left the cursor.
        try await Task.sleep(for: .milliseconds(150))

        #expect(pane.enters == 1)
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func anEnterNeverObservedFailsAfterOneRetryAndTaintsThePane() async throws {
        let pane = ScriptedPane(afterEnter: [ScriptedPane.absorbedScreen, ScriptedPane.absorbedTwiceScreen])
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
        let pane = ScriptedPane(
            afterEnter: [ScriptedPane.absorbedScreen, ScriptedPane.submittedScreen], rebindAfterEnter: true
        )
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
        let harness = adapter(pane, timing: Self.timing(settleLimit: .seconds(5), settleFloor: .milliseconds(300)))
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
        let pane = ScriptedPane(afterEnter: [ScriptedPane.typedScreen], readableAfterEnter: false)
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.unverifiable])
    }
}
