import Testing
@testable import HailDaemonKit

@Suite struct TmuxSendEscapingTests {
    let text = #"he said "hi" \ ; done $(x) `y`"#

    @Test func deliversLiterallyByArgvToTheSessionIdNotTheName() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)

        try await adapter.deliver(text, to: "claude-hail", binding: nil)

        #expect(await runner.calls == [
            ["tmux", "list-sessions", "-F", TmuxAdapter.listFormat],
            ["tmux", "send-keys", "-t", "%1", "-l", "--", text],
            ["tmux", "list-sessions", "-F", TmuxAdapter.listFormat],
            ["tmux", "send-keys", "-t", "%1", "Enter"]
        ])
    }

    @Test func socketPrefixesEveryCall() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, socket: "hail-test", pollInterval: nil)

        _ = try await adapter.capture("codex")

        #expect(await runner.calls == [
            ["tmux", "-L", "hail-test", "list-sessions", "-F", TmuxAdapter.listFormat],
            ["tmux", "-L", "hail-test", "capture-pane", "-p", "-J", "-t", "%2", "-S", "-200"]
        ])
    }

    @Test func escapeIsOneLiteralKeyToTheBoundPane() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)

        try await adapter.escape("codex", binding: "$2@1758230001/%2:502")

        #expect(await runner.calls == [
            ["tmux", "list-sessions", "-F", TmuxAdapter.listFormat],
            ["tmux", "send-keys", "-t", "%2", "Escape"]
        ])
    }

    @Test func unknownNamePrefixAndLineBreaksAreRefusedBeforeAnySend() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)

        await #expect(throws: AdapterError.unknownTarget("claude")) {
            try await adapter.deliver("x", to: "claude", binding: nil)
        }
        await #expect(throws: AdapterError.deliveryFailed("text contains a line break")) {
            try await adapter.deliver("rm -rf x\necho y", to: "codex", binding: nil)
        }
        for empty in ["", "   ", "\t"] {
            await #expect(throws: AdapterError.deliveryFailed("empty text")) {
                try await adapter.deliver(empty, to: "codex", binding: nil)
            }
        }
        #expect(await runner.calls.filter { $0.contains("send-keys") }.isEmpty)
    }

    @Test func bindingFromListingIsHonouredAndAReboundNameIsRefused() async throws {
        let listing = SessionListing(twoSessions)
        let runner = FakeCommandRunner.serving(listing)
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let bound = try #require(try await adapter.listTargets().first { $0.name == "codex" }?.binding)
        #expect(bound == "$2@1758230001/%2:502")

        try await adapter.deliver("ok", to: "codex", binding: bound)
        // codex dies and a new session takes the name; the server restarts and reuses the id; the session
        // survives but its active pane is now another program. Each is a different binding.
        for changed in [
            "$1\t1758230000\t%1\t501\tclaude-hail\n$7\t1758230900\t%9\t900\tcodex\n",
            "$2\t1758239999\t%2\t502\tcodex\n",
            "$2\t1758230001\t%5\t777\tcodex\n"
        ] {
            listing.set(changed)
            await #expect(throws: AdapterError.rebound("codex")) {
                try await adapter.deliver("no", to: "codex", binding: bound)
            }
        }

        let sends = await runner.calls.filter { $0.contains("-l") }
        #expect(sends.map { $0.last } == ["ok"])
    }

    @Test func paneSwitchBetweenChunksAndEnterIsRefused() async throws {
        // The first listing verifies the target; the second, taken right before Enter, sees the active pane
        // of codex replaced by another program (new pane id and pid). The chunks went out, the Enter must not.
        let listings = SessionListing("")
        let calls = SessionListing("0")
        let runner = FakeCommandRunner { arguments in
            guard arguments.contains("list-sessions") else { return CommandResult(exitCode: 0, stdout: "") }
            let count = Int(calls.get()) ?? 0
            calls.set(String(count + 1))
            listings.set(count == 0 ? twoSessions : "$2\t1758230001\t%8\t808\tcodex\n")
            return CommandResult(exitCode: 0, stdout: listings.get())
        }
        let adapter = TmuxAdapter(runner: runner, chunkSize: 2, pollInterval: nil)

        await #expect(throws: AdapterError.rebound("codex")) {
            try await adapter.deliver("abcd", to: "codex", binding: "$2@1758230001/%2:502")
        }

        let sends = await runner.calls.filter { $0.contains("send-keys") }
        #expect(sends.map { $0.last ?? "" } == ["ab", "cd"])
        #expect(sends.allSatisfy { $0.contains("%2") })
    }

    @Test func concurrentDeliveriesNeverInterleaveChunksAndEnters() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions), delay: .milliseconds(5))
        let adapter = TmuxAdapter(runner: runner, chunkSize: 2, pollInterval: nil)

        async let first: Void = adapter.deliver("aaaa", to: "codex", binding: nil)
        async let second: Void = adapter.deliver("bbbb", to: "codex", binding: nil)
        _ = try await (first, second)

        let keys = await runner.calls.filter { $0.contains("send-keys") }.map { $0.last ?? "" }
        let aFirst = ["aa", "aa", "Enter", "bb", "bb", "Enter"]
        let bFirst = ["bb", "bb", "Enter", "aa", "aa", "Enter"]
        #expect(keys == aFirst || keys == bFirst)
    }

    @Test func configuredTmuxPathIsArgvZero() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, tmux: "/opt/homebrew/bin/tmux", pollInterval: nil)

        _ = try await adapter.listTargets()

        #expect(await runner.calls.map { $0[0] } == ["/opt/homebrew/bin/tmux"])
    }

    @Test func noServerListsNothingAndOtherErrorsSurface() async throws {
        let empty = TmuxAdapter(runner: FakeCommandRunner.serving(SessionListing("")), pollInterval: nil)
        #expect(try await empty.listTargets().isEmpty)
        #expect(TmuxAdapter.isNoServer("no server running on /private/tmp/tmux-501/x\n"))
        #expect(TmuxAdapter.isNoServer("error connecting to /private/tmp/tmux-501/x (No such file or directory)\n"))
        #expect(!TmuxAdapter.isNoServer("error connecting to /x (Permission denied)\n"))

        let broken = TmuxAdapter(runner: FakeCommandRunner { _ in
            CommandResult(exitCode: 1, stdout: "", stderr: "error connecting to /x (Permission denied)\n")
        }, pollInterval: nil)
        await #expect(throws: AdapterError.captureFailed("error connecting to /x (Permission denied)")) {
            try await broken.listTargets()
        }
    }
}
