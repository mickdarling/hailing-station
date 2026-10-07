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
            /usr/bin/perl -e 'use POSIX; setpgid(0, 0); open(F, ">escaped.txt"); print F "$$\\n"; close F; sleep 30' &
            while [ ! -s escaped.txt ]; do /bin/sleep 0.05; done
            echo ready
            exit 0
            """)
        defer { fake.cleanUp() }
        let child = try fake.child(Self.quick)
        defer { if let escaped = try? Self.pid(fake, "escaped.txt") { kill(escaped, SIGKILL) } }
        var taken: [Data] = []
        await #expect(throws: RightyoChildError.transportLost) {
            for try await line in child.lines { taken.append(line) }
        }
        #expect(taken == [Data("ready".utf8)])
        #expect(await child.stop() == .exited(0))
    }

    /// End to end: ambient `run()` returns promptly when only the wrapper dies (2m12s unnoticed before #297).
    @Test func theAmbientPipelineEndsWhenOnlyTheWrapperIsKilled() async throws {
        let fake = try FakeRightyo("/bin/sleep 60 &\necho $! > grandchild.txt\n/bin/sleep 60")
        defer { fake.cleanUp() }
        let pipeline = try RightyoAmbientPipeline(configuration: .init(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: Self.quick
        ), dispatcher: RecordingAmbientDispatcher())
        let grandchild = try await Self.waitForPid(fake, "grandchild.txt")
        let wrapper = getpgid(grandchild)
        try #require(wrapper > 1)
        let started = ContinuousClock.now
        #expect(kill(wrapper, SIGTERM) == 0)
        await #expect(throws: (any Error).self) { _ = try await pipeline.run() }
        #expect(ContinuousClock.now - started < .seconds(10))
        try await Self.expectGone(grandchild)
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
