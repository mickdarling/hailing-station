#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// The child's reply-control descriptor (rightyo#124): opt-in, fd 3 only, one atomic JSON line per report.
@Suite(.serialized, .timeLimit(.minutes(1))) struct RightyoChildControlTests {
    @Test func replyControlAddsTheControlArgumentAndOnlyThen() {
        let config = URL(fileURLWithPath: "/tmp/prototype.json")
        let off = RightyoChildProcess.arguments(session: "hail-test", config: config)
        let on = RightyoChildProcess.arguments(session: "hail-test", config: config, replyControl: true)
        #expect(!off.contains("--control-fd"))
        #expect(on == off + ["--control-fd", "3"])
    }

    /// Every child-side pipe end is lifted above the `dup2` targets (0-3) before spawning, so no `dup2` source can be
    /// clobbered by an earlier action or be same-fd (review of #341: with fd 3 free, a pipe end could land on 3).
    @Test(arguments: [0, 1]) func secureLiftsTheChildEndAboveEveryTargetAndMarksBothCloseOnExec(child: Int) throws {
        var ends = [Int32](repeating: -1, count: 2)
        #expect(pipe(&ends) == 0)
        let original = ends[child]
        #expect(RightyoChildProcess.secure(&ends, child: child))
        defer { ends.forEach { close($0) } }
        #expect(ends[child] > RightyoChildProcess.controlDescriptor)
        #expect(ends.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
        if original != ends[child] { #expect(fcntl(original, F_GETFD) == -1 || original <= 3) }
    }

    @Test func reportsReachTheChildOnDescriptorThreeAsJSONLines() async throws {
        let fake = try FakeRightyo("""
            printf '%s\\n' "$@" > argv.txt
            /bin/cat <&3 > control.txt
            """)
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config, session: "hail-test",
                                            timing: .init(eofGrace: 20, termGrace: 20), replyControl: true)
        #expect(child.reportReply(.started))
        #expect(child.reportReply(.ended))
        // Closing input ends the control descriptor too, so `cat` sees EOF and the child exits.
        #expect(await child.stop() == .exited(0))
        #expect(try fake.recorded("control.txt") == "{\"reply\":\"started\"}\n{\"reply\":\"ended\"}\n")
        #expect(try fake.recorded("argv.txt").hasSuffix("--control-fd\n3\n"))
        #expect(!child.reportReply(.ended))
    }

    @Test func withoutReplyControlTheChildHasNoDescriptorThreeAndReportsAreRefused() async throws {
        let fake = try FakeRightyo("if : <&3; then echo open > fd3.txt; else echo closed > fd3.txt; fi 2>/dev/null")
        defer { fake.cleanUp() }
        let child = try fake.child()
        #expect(!child.reportReply(.started))
        #expect(await child.stop() == .exited(0))
        #expect(try fake.recorded("fd3.txt") == "closed\n")
    }

    @Test func aChildThatNeverReadsControlNeverBlocksTheHost() async throws {
        let fake = try FakeRightyo("echo ready\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try RightyoChildProcess(executable: FakeRightyo.shared, config: fake.config, session: "hail-test",
                                            timing: .init(eofGrace: 0.5, termGrace: 0.5), replyControl: true)
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        // Far more than a pipe holds: once full, reports are dropped, never waited on.
        var accepted = 0
        for _ in 0..<10_000 where child.reportReply(.started) { accepted += 1 }
        #expect(accepted > 0 && accepted < 10_000)
        _ = await child.stop()
    }
}
#endif
