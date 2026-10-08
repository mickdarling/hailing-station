import Testing
@testable import HailDaemonKit

@Suite struct TmuxChunkingTests {
    @Test func thousandCharactersFillOneBufferInThreeCallsAndArriveAsOnePaste() async throws {
        let text = String(repeating: "abcdefghij", count: 100)
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)

        try await adapter.deliver(text, to: "codex", binding: nil)

        let fills = await runner.calls.filter { $0.contains("set-buffer") }
        #expect(fills.map { $0.contains("-a") } == [false, true, true])
        #expect(fills.compactMap(\.last).map(\.count) == [400, 400, 200])
        #expect(await runner.calls.filter { $0.contains("paste-buffer") }.count == 1)
        #expect(await runner.delivered == [text, "Enter"])
        #expect(await runner.calls.last == ["tmux", "send-keys", "-t", "%2", "Enter"])
    }

    @Test func chunkBoundariesNeverSplitAGraphemeCluster() {
        let family = "👨‍👩‍👧"
        let text = String(repeating: "a", count: 399) + family + "b"
        #expect(TmuxAdapter.chunks(text, size: 400) == [String(repeating: "a", count: 399) + family, "b"])
        #expect(TmuxAdapter.chunks("", size: 400).isEmpty)
        #expect(TmuxAdapter.chunks("abc", size: 1) == ["a", "b", "c"])
    }

    @Test func aTrailingSemicolonIsEscapedForTmuxOnce() {
        #expect(TmuxAdapter.bufferArgument("abc") == "abc")
        #expect(TmuxAdapter.bufferArgument("abc;") == #"abc\;"#)
        #expect(TmuxAdapter.bufferArgument(";") == #"\;"#)
        #expect(TmuxAdapter.bufferArgument(#"abc\;"#) == #"abc\\;"#)
        #expect(TmuxAdapter.bufferArgument("a;b") == "a;b")
    }
}
