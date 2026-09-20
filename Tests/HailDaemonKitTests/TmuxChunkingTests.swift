import Testing
@testable import HailDaemonKit

@Suite struct TmuxChunkingTests {
    @Test func thousandCharactersArriveInThreeLiteralSendsAndOneEnter() async throws {
        let text = String(repeating: "abcdefghij", count: 100)
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)

        try await adapter.deliver(text, to: "codex", binding: nil)

        let calls = await runner.calls
        let sends = calls.compactMap { call in call.firstIndex(of: "--").map { call[call.index(after: $0)] } }
        #expect(sends.map(\.count) == [400, 400, 200])
        #expect(sends.joined() == text)
        #expect(await runner.calls.last == ["tmux", "send-keys", "-t", "%2", "Enter"])
    }

    @Test func chunkBoundariesNeverSplitAGraphemeCluster() {
        let family = "👨‍👩‍👧"
        let text = String(repeating: "a", count: 399) + family + "b"
        #expect(TmuxAdapter.chunks(text, size: 400) == [String(repeating: "a", count: 399) + family, "b"])
        #expect(TmuxAdapter.chunks("", size: 400).isEmpty)
        #expect(TmuxAdapter.chunks("abc", size: 1) == ["a", "b", "c"])
    }
}
