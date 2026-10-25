import Testing
@testable import HailDaemonKit

/// #894 ask 1: `haild targets flush` clears a stale prompt draft with End and one BSpace per character, under the tmux
/// server's agent check, and never sends Escape or C-c. Every refusal sends nothing. Scripted runner, synthetic text.
@Suite struct TmuxFlushTests {
    private let target = "claude-hail"

    private func flush(_ harness: FlushHarness) async throws -> TmuxFlushResult {
        let draft = try await harness.adapter.promptDraft(target, binding: FlushHarness.binding)
        return try await harness.adapter.flushPrompt(target, binding: FlushHarness.binding, expecting: draft)
    }

    @Test func theClearIsEndThenExactlyOneBackspacePerCharacterUnderTheAgentGate() async throws {
        let harness = FlushHarness(FlushPane("ZULIP", cursor: 2))
        let draft = try await harness.adapter.promptDraft(target, binding: FlushHarness.binding)
        #expect(draft.text == "ZULIP")
        #expect(await harness.sends.isEmpty, "reading the draft sends nothing")
        let result = try await harness.adapter.flushPrompt(target, binding: FlushHarness.binding, expecting: draft)
        #expect(result == TmuxFlushResult(clearedCharacters: 5, isEmpty: true, textAfterCursor: false))
        #expect(await harness.sends == [
            FlushHarness.gated(["End"]), FlushHarness.gated(Array(repeating: "BSpace", count: 5))
        ])
        #expect(harness.pane.keys == ["End"] + Array(repeating: "BSpace", count: 5))
        await harness.expectNoInterrupt()
        // The binding is checked before each key command.
        let calls = await harness.runner.calls
        for send in calls.indices where calls[send].contains("if-shell") {
            #expect(calls[send - 1].contains("list-sessions"))
        }
        #expect(harness.evidence.all.isEmpty, "a flush writes no log evidence")
    }

    @Test func trailingBlanksTheCaptureDropsAreClearedToo() async throws {
        let harness = FlushHarness(FlushPane("hi  ", cursor: 0))
        let result = try await flush(harness)
        #expect(result.clearedCharacters == 4 && result.isEmpty)
        #expect(harness.pane.keys == ["End", "BSpace", "BSpace", "BSpace", "BSpace"])
        await harness.expectNoInterrupt()
    }

    @Test func eachRefusalSendsNothing() async throws {
        let cases: [(FlushPane, TmuxFlushRefusal)] = [
            (Self.pane("ZULIP") { $0.agent = false }, .notAgent),
            (Self.pane("first") { $0.below = ["  second", "────"] }, .multiLine),
            (FlushPane("[Pasted text #1 +3 lines]"), .placeholder),
            (Self.pane("ls") { $0.prompt = "$ " }, .noMarker)
        ]
        for (pane, refusal) in cases {
            let harness = FlushHarness(pane)
            await #expect(throws: refusal) { _ = try await flush(harness) }
            #expect(await harness.sends.isEmpty, "\(refusal)")
            await harness.expectNoInterrupt()
        }
    }

    @Test func aPaneThatStopsBeingAnAgentAfterThePreviewGetsNoKeys() async throws {
        let harness = FlushHarness(FlushPane("ZULIP"))
        let draft = try await harness.adapter.promptDraft(target, binding: FlushHarness.binding)
        harness.pane.state.withLock { $0.agent = false }
        await #expect(throws: TmuxFlushRefusal.notAgent) {
            _ = try await harness.adapter.flushPrompt(target, binding: FlushHarness.binding, expecting: draft)
        }
        #expect(harness.pane.keys.isEmpty)
        await harness.expectNoInterrupt()
    }

    @Test func aDraftThatChangedIsNeverCleared() async throws {
        // Changed after the preview: nothing is sent.
        let harness = FlushHarness(FlushPane("ZULIP"))
        let draft = try await harness.adapter.promptDraft(target, binding: FlushHarness.binding)
        harness.pane.state.withLock { $0.input = Array("ZULIP and more") }
        await #expect(throws: TmuxFlushRefusal.changed) {
            _ = try await harness.adapter.flushPrompt(target, binding: FlushHarness.binding, expecting: draft)
        }
        #expect(await harness.sends.isEmpty)
        // Changed as the End arrived (an agent redraw, a keystroke): only the End, which deletes nothing, was sent.
        let redrawn = FlushHarness(Self.pane("ZULIP") { $0.onEnd = { $0.input = Array("ZULIPX") } })
        await #expect(throws: TmuxFlushRefusal.changed) { _ = try await flush(redrawn) }
        #expect(redrawn.pane.keys == ["End"])
        await redrawn.expectNoInterrupt()
    }

    @Test func aReboundTargetGetsNoKeys() async throws {
        let harness = FlushHarness(FlushPane("ZULIP"))
        let draft = try await harness.adapter.promptDraft(target, binding: FlushHarness.binding)
        // The same name and pane id, behind a new session (another creation time).
        harness.pane.state.withLock { $0.listing = "$1|1758239999|%1|501|claude-hail\n" }
        await #expect(throws: AdapterError.rebound(target)) {
            _ = try await harness.adapter.flushPrompt(target, binding: FlushHarness.binding, expecting: draft)
        }
        #expect(await harness.sends.isEmpty)
    }

    @Test func anAgentHintThatEndCannotPassIsNotClearedAndNotCalledEmpty() async throws {
        let harness = FlushHarness(Self.pane("") { $0.hint = "Try \"fix lint errors\"" })
        let draft = try await harness.adapter.promptDraft(target, binding: FlushHarness.binding)
        #expect(draft.cursorAtStart && !draft.isEmpty)
        let result = try await harness.adapter.flushPrompt(target, binding: FlushHarness.binding, expecting: draft)
        #expect(result == TmuxFlushResult(clearedCharacters: 0, isEmpty: false, textAfterCursor: true))
        #expect(result.logLine == "targets_flush cleared_chars=0 result=not_empty reason=text_after_cursor")
        #expect(harness.pane.keys == ["End"])
    }

    @Test func textLeftAfterTheClearIsReportedNotEmpty() async throws {
        let stuck = FlushHarness(Self.pane("ZULIP") { $0.ignoresBackspace = true })
        let result = try await flush(stuck)
        #expect(result == TmuxFlushResult(clearedCharacters: 5, isEmpty: false, textAfterCursor: false))
        #expect(result.logLine == "targets_flush cleared_chars=5 result=not_empty reason=text_left")
        await stuck.expectNoInterrupt()
    }

    private static func pane(_ input: String, _ change: (inout FlushPane.State) -> Void) -> FlushPane {
        let pane = FlushPane(input)
        pane.state.withLock { change(&$0) }
        return pane
    }
}
