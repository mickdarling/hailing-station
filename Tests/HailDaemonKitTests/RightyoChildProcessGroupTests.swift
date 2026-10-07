#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// The child leads its own process group and the whole group is supervised (#297): a wrapper that exits or is
/// killed alone, leaving descendants holding the stdio pipes, still ends the stream promptly, and the descendants
/// are ended with it. The name keeps the suite in verify.sh's serial timing lane (`RightyoChildProcess`).
@Suite(.serialized, .timeLimit(.minutes(1))) struct RightyoChildProcessGroupTests {
    /// A grandchild that outlives its wrapper while holding stdout; its pid is in `grandchild.txt` before `ready`.
    static let orphaning = "/bin/sleep 60 &\necho $! > grandchild.txt\necho ready"
    static let quick = RightyoChildProcess.Timing(eofGrace: 0.5, termGrace: 0.5)

    @Test func theChildLeadsANewProcessGroup() async throws {
        let fake = try FakeRightyo("echo ready\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        #expect(getpgid(child.processIdentifier) == child.processIdentifier)
        #expect(getpgid(child.processIdentifier) != getpgrp())
        #expect(await child.stop() == .signaled(SIGTERM))
    }

    @Test func aWrapperThatExitsLeavingAGrandchildOnStdoutStillEndsTheStream() async throws {
        let fake = try FakeRightyo(Self.orphaning + "\nexit 0")
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        let started = ContinuousClock.now
        var taken: [Data] = []
        for try await line in child.lines { taken.append(line) }
        #expect(taken == [Data("ready".utf8)])
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await child.stop() == .exited(0))
        try await Self.expectGone(try Self.pid(fake, "grandchild.txt"))
    }

    /// The incident shape: only the wrapper is killed, from outside, while its pipeline keeps running.
    @Test func killingOnlyTheWrapperEndsTheStreamAndTheGroup() async throws {
        let fake = try FakeRightyo(Self.orphaning + "\n/bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        let grandchild = try Self.pid(fake, "grandchild.txt")
        let started = ContinuousClock.now
        #expect(kill(child.processIdentifier, SIGTERM) == 0)
        #expect(try await lines.next() == nil)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await child.stop() == .signaled(SIGTERM))
        try await Self.expectGone(grandchild)
    }

    @Test func aGrandchildIgnoringSIGTERMIsKilledAfterTheGrace() async throws {
        let fake = try FakeRightyo("trap '' TERM\n" + Self.orphaning + "\nexit 0")
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        let started = ContinuousClock.now
        for try await _ in child.lines {}
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await child.stop() == .exited(0))
        try await Self.expectGone(try Self.pid(fake, "grandchild.txt"))
    }

    @Test func stopSignalsTheWholeGroup() async throws {
        let fake = try FakeRightyo(Self.orphaning + "\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        #expect(await child.stop() == .signaled(SIGTERM))
        try await Self.expectGone(try Self.pid(fake, "grandchild.txt"))
        #expect(try await lines.next() == nil)
    }

    /// A descendant that left the group cannot be signalled; the leader's exit still ends the stream.
    @Test func aDescendantThatLeftTheGroupCannotHoldTheStreamOpen() async throws {
        let fake = try FakeRightyo("""
            /usr/bin/perl -e 'use POSIX; setpgid(0, 0); open(F, ">escaped.txt"); print F "$$\\n"; close F; sleep 5' &
            while [ ! -s escaped.txt ]; do /bin/sleep 0.05; done
            echo ready
            exit 0
            """)
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        // The escapee exits by itself within 5 s; it is killed early only while that pid is still the perl that
        // leads its own group.
        defer {
            if let escaped = try? Self.pid(fake, "escaped.txt"), Self.isEscapedPerl(escaped) { kill(escaped, SIGKILL) }
        }
        var taken: [Data] = []
        await #expect(throws: RightyoChildError.transportLost) {
            for try await line in child.lines { taken.append(line) }
        }
        #expect(taken == [Data("ready".utf8)])
        #expect(await child.stop() == .exited(0))
    }

    /// End to end: ambient `run()` returns promptly when only the wrapper dies (2m12s unnoticed before #297).
    @Test func theAmbientPipelineEndsWhenOnlyTheWrapperIsKilled() async throws {
        let fake = try FakeRightyo("echo $$ > wrapper.txt\n/bin/sleep 60 &\necho $! > grandchild.txt\n/bin/sleep 60")
        defer { fake.cleanUp() }
        let pipeline = try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: Self.quick
        ), dispatcher: RecordingAmbientDispatcher())
        let grandchild = try await Self.waitForPid(fake, "grandchild.txt")
        let wrapper = try Self.pid(fake, "wrapper.txt")
        // Never signal the test runner's own group leader, even if the group regressed.
        try #require(wrapper > 1 && wrapper != getpgrp() && getpgid(wrapper) == wrapper)
        let started = ContinuousClock.now
        #expect(kill(wrapper, SIGTERM) == 0)
        await #expect(throws: (any Error).self) { _ = try await pipeline.run() }
        #expect(ContinuousClock.now - started < .seconds(10))
        try await Self.expectGone(grandchild)
    }

    /// Exit readiness raced with waitable status (#297 review): every quick-exit leader must still settle.
    @Test func manyQuickExitLeadersAllSettle() async throws {
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        let truth = URL(fileURLWithPath: "/usr/bin/true")
        for _ in 0..<150 {
            try await withThrowingTaskGroup(of: (RightyoChildExit, Duration).self) { group in
                for _ in 0..<20 {
                    let child = try RightyoChildProcess(executable: truth, config: fake.config, session: "hail-test",
                                                        timing: Self.quick)
                    group.addTask {
                        let started = ContinuousClock.now
                        return (await child.stop(), ContinuousClock.now - started)
                    }
                }
                for try await (exit, took) in group {
                    #expect(exit == .exited(0))
                    #expect(took < .seconds(2))
                }
            }
        }
    }

    /// A leader that moved itself into another existing group is still signalled by its own pid.
    @Test func aLeaderThatChangedGroupIsStillStopped() async throws {
        let fake = try FakeRightyo("""
            exec /usr/bin/perl -e '$| = 1; setpgrp(0, getpgrp(getppid())) or die; print "ready\\n"; sleep 30'
            """)
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        var lines = child.lines.makeAsyncIterator()
        #expect(try await lines.next() == Data("ready".utf8))
        #expect(getpgid(child.processIdentifier) == getpgrp())
        let started = ContinuousClock.now
        #expect(await child.stop() == .signaled(SIGTERM))
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

extension RightyoChildProcessGroupTests {
    static func isEscapedPerl(_ pid: pid_t) -> Bool {
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard getpgid(pid) == pid else { return false }
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        return length > 0 && (String(bytes: path.prefix(Int(length)), encoding: .utf8) ?? "").contains("perl")
    }

    static func pid(_ fake: FakeRightyo, _ name: String) throws -> pid_t {
        try #require(pid_t(try fake.recorded(name).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    static func waitForPid(_ fake: FakeRightyo, _ name: String) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            if let pid = try? pid(fake, name) { return pid }
            try #require(ContinuousClock.now < deadline, "\(name) never written")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The orphan is re-parented to launchd, which reaps it; ESRCH means it is gone.
    static func expectGone(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while kill(pid, 0) == 0 || errno != ESRCH {
            try #require(ContinuousClock.now < deadline, "descendant \(pid) outlived the group")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
#endif
