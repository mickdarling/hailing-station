import Testing
@testable import HailDaemonKit

@Suite struct TmuxSendEscapingTests {
    let text = #"he said "hi" \ ; done $(x) `y`"#

    @Test func deliversLiterallyByArgvToTheSessionIdNotTheName() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)

        try await adapter.deliver(text, to: "claude-hail", binding: nil)

        let calls = await runner.calls
        let buffer = try #require(calls.first { $0.contains("set-buffer") }?[3])
        #expect(buffer.hasPrefix("hail-") && buffer.count > 20, "a unique buffer per delivery")
        let observe = ["tmux", "capture-pane", "-p", "-t", "%1", ";",
                       "display-message", "-p", "-t", "%1", PaneObservation.cursorFormat]
        #expect(calls == [
            ["tmux", "list-sessions", "-F", TmuxAdapter.listFormat],
            // A baseline before the text (#83, #304), the text into a buffer by argv, the identity, the paste in
            // one piece, then a look at the pane (unreadable here, so nothing to wait for) and the identity again.
            observe,
            ["tmux", "set-buffer", "-b", buffer, "--", text],
            ["tmux", "list-sessions", "-F", TmuxAdapter.listFormat],
            ["tmux", "paste-buffer", "-p", "-d", "-b", buffer, "-t", "%1"],
            observe,
            ["tmux", "list-sessions", "-F", TmuxAdapter.listFormat],
            ["tmux", "send-keys", "-t", "%1", "Enter"]
        ])
    }

    @Test func aFailedPasteDeletesItsBufferAndSendsNoEnter() async throws {
        let runner = FakeCommandRunner { arguments in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
            if arguments.contains("paste-buffer") { return CommandResult(exitCode: 1, stdout: "", stderr: "no pane") }
            return CommandResult(exitCode: 0, stdout: "")
        }
        let adapter = TmuxAdapter(runner: runner, chunkSize: 2, pollInterval: nil)

        await #expect(throws: AdapterError.deliveryFailed("no pane")) {
            try await adapter.deliver("abcd", to: "codex", binding: nil)
        }
        let calls = await runner.calls
        let buffer = try #require(calls.first { $0.contains("set-buffer") }?[3])
        #expect(calls.filter { $0.contains("set-buffer") }.map { Array($0.dropFirst()) } == [
            ["set-buffer", "-b", buffer, "--", "ab"], ["set-buffer", "-a", "-b", buffer, "--", "cd"]
        ])
        #expect(calls.last == ["tmux", "delete-buffer", "-b", buffer])
        #expect(!calls.contains { $0.contains("send-keys") })
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
        #expect(await runner.calls.filter { $0.contains("send-keys") || $0.contains("set-buffer") }.isEmpty)
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
            "$1|1758230000|%1|501|claude-hail\n$7|1758230900|%9|900|codex\n",
            "$2|1758239999|%2|502|codex\n",
            "$2|1758230001|%5|777|codex\n"
        ] {
            listing.set(changed)
            await #expect(throws: AdapterError.rebound("codex")) {
                try await adapter.deliver("no", to: "codex", binding: bound)
            }
        }

        #expect(await runner.delivered == ["ok", "Enter"])
    }

    @Test func paneSwitchBetweenPasteAndEnterIsRefused() async throws {
        // The first two listings verify the target (before the fill and before the paste); the third, taken right
        // before Enter, sees the active pane of codex replaced by another program (new pane id and pid). The paste
        // went out, the Enter must not.
        let listings = SessionListing("")
        let calls = SessionListing("0")
        let runner = FakeCommandRunner { arguments in
            guard arguments.contains("list-sessions") else { return CommandResult(exitCode: 0, stdout: "") }
            let count = Int(calls.get()) ?? 0
            calls.set(String(count + 1))
            listings.set(count < 2 ? twoSessions : "$2|1758230001|%8|808|codex\n")
            return CommandResult(exitCode: 0, stdout: listings.get())
        }
        let adapter = TmuxAdapter(runner: runner, chunkSize: 2, pollInterval: nil)

        await #expect(throws: AdapterError.rebound("codex")) {
            try await adapter.deliver("abcd", to: "codex", binding: "$2@1758230001/%2:502")
        }

        #expect(await runner.delivered == ["abcd"], "the paste went out, the Enter must not")
        let toPane = await runner.calls.filter { $0.contains("paste-buffer") || $0.contains("capture-pane") }
        #expect(toPane.allSatisfy { $0.contains("%2") })
    }

    @Test func concurrentDeliveriesNeverInterleaveFillsPastesAndEnters() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions), delay: .milliseconds(5))
        let adapter = TmuxAdapter(runner: runner, chunkSize: 2, pollInterval: nil)

        async let first: Void = adapter.deliver("aaaa", to: "codex", binding: nil)
        async let second: Void = adapter.deliver("bbbb", to: "codex", binding: nil)
        _ = try await (first, second)

        let keys = await runner.delivered
        #expect(keys == ["aaaa", "Enter", "bbbb", "Enter"] || keys == ["bbbb", "Enter", "aaaa", "Enter"])
        // Each delivery fills its own buffer; one buffer's fills never interleave with the other's paste.
        let typing = await runner.calls.filter { $0.contains("set-buffer") || $0.contains("paste-buffer") }
        let order = typing.compactMap { call in call.firstIndex(of: "-b").map { call[$0 + 1] } }
        let runs = order.reduce(into: [String]()) { runs, name in if runs.last != name { runs.append(name) } }
        #expect(runs.count == 2)
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
