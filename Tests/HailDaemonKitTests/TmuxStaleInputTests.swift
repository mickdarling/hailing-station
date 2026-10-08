import Testing
@testable import HailDaemonKit

/// #304: text already pending at the cursor is never appended to.
@Suite struct TmuxStaleInputTests {
    private static let fast = TmuxSubmitTiming(
        settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
        settleLimit: .seconds(5), confirmLimit: .milliseconds(60)
    )

    @Test func theSameTextAlreadyAtTheCursorIsRefusedBeforeAnyPasteAndNotTainted() async throws {
        let pane = ScriptedPane(baseline: ScriptedPane.typedScreen)
        let harness = SubmitHarness(pane, timing: Self.fast)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(await harness.runner.calls.allSatisfy { !$0.contains("set-buffer") && !$0.contains("send-keys") })
        // Cleared by hand: the pane is used again, since nothing was pasted.
        pane.reset(baseline: ScriptedPane.oldScreen)
        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func theLastDeliveredTextStillAtTheCursorIsRefused() async throws {
        let pane = ScriptedPane()
        let harness = SubmitHarness(pane, timing: Self.fast)
        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        // The next look finds the last text back at the cursor (an Enter undone, a TUI that restored its input).
        pane.reset(baseline: ScriptedPane.absorbedScreen)
        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("a different request", to: "codex", binding: nil)
        }
        #expect(await harness.keys == ["synthetic input", "Enter"])
    }

    @Test func aPastePlaceholderLeftInTheInputIsRefused() async throws {
        let pane = ScriptedPane(baseline: "> [Pasted text #3 +1 lines]▌")
        let harness = SubmitHarness(pane, timing: Self.fast)

        await #expect(throws: AdapterError.self) {
            try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        #expect(await harness.keys.isEmpty)
    }
}

/// #304: what counts as the text at the cursor, beyond the literal tail.
@Suite struct TmuxCursorInputTests {
    private func adapter(_ pane: ScriptedPane) -> SubmitHarness {
        SubmitHarness(pane, timing: TmuxSubmitTiming(
            settleFloor: .milliseconds(1), pollInterval: .milliseconds(2), quiet: .milliseconds(6),
            settleLimit: .seconds(5), confirmLimit: .milliseconds(60)
        ))
    }

    @Test func aTerminalThatEndsTheLineConfirmsWithOneEnter() async throws {
        let pane = ScriptedPane(afterEnter: [ScriptedPane.lineEndedScreen])
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }

    @Test func aPastePlaceholderAtTheCursorCountsAsTheText() async throws {
        let pane = ScriptedPane(
            typed: "> [Pasted text #2 +0 lines]▌", afterEnter: ["> [Pasted text #2 +0 lines]\n\n> ▌"]
        )
        let harness = adapter(pane)

        try await harness.adapter.deliver("synthetic input", to: "codex", binding: nil)

        #expect(await harness.keys == ["synthetic input", "Enter"])
        #expect(harness.log.all == [.confirmed])
    }
}
