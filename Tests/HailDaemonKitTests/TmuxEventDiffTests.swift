import Testing
@testable import HailDaemonKit

@Suite struct TmuxEventDiffTests {
    typealias Session = TmuxAdapter.Session

    func session(_ id: String, _ name: String, pane: String = "%1", pid: String = "1") -> Session {
        Session(id: id, created: "1", paneID: pane, panePID: pid, name: name)
    }

    @Test func diffIsByBindingVanishedThenAppearedSortedByName() {
        let old = [session("$1", "b"), session("$2", "a")]
        let new = [session("$2", "a"), session("$3", "c"), session("$4", "0")]
        #expect(TmuxAdapter.diff(old: old, new: new) == [
            .vanished(name: "b"),
            .appeared(AdapterTarget(name: "0", binding: "$4@1/%1:1")),
            .appeared(AdapterTarget(name: "c", binding: "$3@1/%1:1"))
        ])
        #expect(TmuxAdapter.diff(old: new, new: new).isEmpty)
    }

    @Test func replacementUnderTheSameNameIsAVanishAndAnAppear() {
        let before = [session("$1", "foo")]
        let replaced = [session("$5", "foo")]
        let paneChanged = [session("$1", "foo", pane: "%3", pid: "42")]
        #expect(TmuxAdapter.diff(old: before, new: replaced) == [
            .vanished(name: "foo"), .appeared(AdapterTarget(name: "foo", binding: "$5@1/%1:1"))
        ])
        #expect(TmuxAdapter.diff(old: before, new: paneChanged) == [
            .vanished(name: "foo"), .appeared(AdapterTarget(name: "foo", binding: "$1@1/%3:42"))
        ])
    }

    @Test func parseSkipsMalformedLinesAndKeepsTabsInNames() {
        let out = "$1\t10\t%1\t5\tclaude-hail\n\n$2\t11\t%2\t6\ta\tb\nbroken\n"
            + "\t1\t%1\t1\tnoid\n$3\t12\t%3\t7\t\n$4\t1\t%4\tnoname\n"
        let expected = [
            Session(id: "$1", created: "10", paneID: "%1", panePID: "5", name: "claude-hail"),
            Session(id: "$2", created: "11", paneID: "%2", panePID: "6", name: "a\tb")
        ]
        #expect(TmuxAdapter.parseSessions(out) == expected)
    }

    @Test func pollingEmitsAppearAndVanishWithinTheInterval() async throws {
        let sessions = SessionListing("$1\t1\t%1\t1\ta\n")
        let adapter = TmuxAdapter(
            runner: FakeCommandRunner.serving(sessions), pollInterval: .milliseconds(20)
        )
        var seen: [TargetEvent] = []
        for await event in adapter.events {
            seen.append(event)
            switch seen.count {
            case 1: sessions.set("$1\t1\t%1\t1\ta\n$2\t2\t%2\t2\tb\n")
            case 2: sessions.set("")
            case 4: break
            default: continue
            }
            if seen.count == 4 { break }
        }
        #expect(seen == [
            .appeared(AdapterTarget(name: "a", binding: "$1@1/%1:1")),
            .appeared(AdapterTarget(name: "b", binding: "$2@2/%2:2")),
            .vanished(name: "a"), .vanished(name: "b")
        ])
    }

    @Test func nothingPollsUntilSomeoneIteratesEvents() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(40))
        #expect(await runner.calls.isEmpty)
        _ = adapter
    }

    @Test func aLateConsumerStillSeesEverySession() async throws {
        let listing = (1...70).map { "$\($0)\t1\t%\($0)\t\($0)\ts\($0)\n" }.joined()
        let runner = FakeCommandRunner.serving(SessionListing(listing))
        let adapter = TmuxAdapter(runner: runner, pollInterval: .milliseconds(5))
        let stream = adapter.events
        try await Task.sleep(for: .milliseconds(60))   // several polls before anyone reads

        var seen = Set<String>()
        for await event in stream {
            if case .appeared(let target) = event { seen.insert(target.name) }
            if seen.count == 70 { break }
        }
        #expect(seen.count == 70)
    }

    @Test func nilIntervalGivesAFinishedStream() async {
        let runner = FakeCommandRunner { _ in CommandResult(exitCode: 0, stdout: "") }
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        var count = 0
        for await _ in adapter.events { count += 1 }
        #expect(count == 0)
    }
}
