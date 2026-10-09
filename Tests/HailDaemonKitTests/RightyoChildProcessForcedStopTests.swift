#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// #366: a retired ambient child can be made to give way at once with short, explicit graces, whatever its own
/// (long) timing says. Real processes, so serialized like the other child suites.
@Suite(.serialized, .timeLimit(.minutes(1))) struct RightyoChildProcessForcedStopTests {
    @Test func shortGracesKillAChildThatIgnoresEOFAndSIGTERMWithinThem() async throws {
        let fake = try FakeRightyo("trap '' TERM\necho ready\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        // Its own timing would wait 20 s for EOF and 20 s more after SIGTERM.
        let child = try fake.child(.init(eofGrace: 20, termGrace: 20))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        let started = ContinuousClock.now
        #expect(await child.stop(eofGrace: 0.3, termGrace: 0.3) == .signaled(SIGKILL))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(child.exitStatus == .signaled(SIGKILL))
    }

    @Test func aChildThatExitsOnEOFIsNotSignalled() async throws {
        let fake = try FakeRightyo("/usr/bin/wc -c > /dev/null")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 20, termGrace: 20))
        #expect(await child.stop(eofGrace: 1, termGrace: 1) == .exited(0))
    }

    @Test func aForcedStopBesideAnOrdinaryStopEndsBoth() async throws {
        let fake = try FakeRightyo("trap '' TERM\necho ready\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try fake.child(.init(eofGrace: 20, termGrace: 20))
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        let ordinary = Task { await child.stop() }
        #expect(await child.stop(eofGrace: 0.3, termGrace: 0.3) == .signaled(SIGKILL))
        #expect(await ordinary.value == .signaled(SIGKILL))
    }
}
#endif
