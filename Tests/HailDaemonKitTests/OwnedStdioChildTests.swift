#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit
private struct WeakStdioChild: Sendable { weak var value: OwnedStdioChild? }

@Suite struct OwnedStdioChildTests {
    @Test func cancelledJoinedSourcesReleaseTheirOwner() async throws {
        let reference = Mutex(WeakStdioChild())
        do {
            let child = try await CodexStdioFixtures.withChild(CodexStdioFixtures.echo, grace: 0.02) { child in
                reference.withLock { $0.value = child }
                return child
            }
            #expect(child.isReaped)
        }
        try await CodexStdioFixtures.waitUntil { reference.withLock { $0.value == nil } }
        #expect(reference.withLock { $0.value == nil })
    }
    @Test func immediateExitAroundSourceRegistrationStillClosesAndReaps() async throws {
        for _ in 0..<12 {
            let command = OwnedStdioCommand(executable: "/usr/bin/true")
            let child = try await CodexStdioFixtures.withChild(command, grace: 0.02) { child in
                for try await _ in child.chunks {} // Safety-triggered stopped is a failure, not accepted EOF.
                return child
            }
            #expect(child.isReaped)
        }
    }
    @Test func idleReadyChildDoesNotPollReadOrReap() async throws {
        let command = CodexStdioFixtures.command(#"print "ready\n"; while(<STDIN>) {}"#)
        let child = try await CodexStdioFixtures.withChild(command) { child in
            #expect(try await CodexStdioFixtures.firstChunk(child) == Data("ready\n".utf8))
            try await Task.sleep(for: .milliseconds(100))
            #expect(!child.isStopped && !child.isReaped)
            #expect(child.ioChecks.reads <= 4) // Initial drain/EAGAIN only, not recurring idle syscalls.
            #expect(child.ioChecks.reaps == 1) // The single startup registration-race check.
            return child
        }
        #expect(child.isReaped)
    }
    @Test func actualPipesEchoAndReapedCleanup() async throws {
        let child = try await CodexStdioFixtures.withChild(CodexStdioFixtures.echo) { child in
            try await child.write(Data("{\"id\":1}\n".utf8))
            let result = try await CodexStdioFixtures.firstChunk(child)
            #expect(String(data: result, encoding: .utf8) == "{\"id\":1,\"result\":{\"ok\":true}}\n")
            child.cancel(); child.cancel(); await child.join()
            return child
        }
        #expect(child.isReaped)
        await #expect(throws: CodexStdioError.stopped) { try await child.write(Data([10])) }
    }
    @Test func ignoredSIGTERMEscalatesAndActuallyReaps() async throws {
        let command = CodexStdioFixtures.command(
            #"$SIG{TERM}='IGNORE'; print "ready\n"; while(1) { select undef,undef,undef,1; }"#)
        let child = try await CodexStdioFixtures.withChild(command, grace: 0.02) { child in
            let ready = try await CodexStdioFixtures.firstChunk(child)
            #expect(ready == Data("ready\n".utf8))
            let began = ContinuousClock().now
            child.cancel(); await child.join()
            #expect(began.duration(to: .now) < .seconds(2))
            return child
        }
        #expect(child.isReaped)
    }
    @Test func nonReadingChildWriteCancellationUnblocksAndReaps() async throws {
        let command = CodexStdioFixtures.command(
            #"$SIG{TERM}='IGNORE'; print "ready\n"; while(1) { select undef,undef,undef,1; }"#)
        let child = try await CodexStdioFixtures.withChild(command, grace: 0.02) { child in
            _ = try await CodexStdioFixtures.firstChunk(child)
            let write = Task { try await child.write(Data(repeating: 65, count: 65_537)) }
            await Task.yield()
            child.cancel(); await child.join()
            await #expect(throws: CodexStdioError.stopped) { try await write.value }
            return child
        }
        #expect(child.isReaped)
    }
    @Test func closedPipeDoesNotRaiseSIGPIPEOrExposeErrno() async throws {
        let command = CodexStdioFixtures.command(
            #"close STDIN; print "ready\n"; while(1) { select undef,undef,undef,1; }"#)
        let child = try await CodexStdioFixtures.withChild(command) { child in
            _ = try await CodexStdioFixtures.firstChunk(child)
            await #expect(throws: CodexStdioError.transportLost) { try await child.write(Data([65])) }
            await child.join(); return child
        }
        #expect(child.isReaped)
    }
    @Test func chunkOverflowCancelsAndReapsWithoutUnboundedRetention() async throws {
        let command = CodexStdioFixtures.command(#"print 'x' x 100000; while(1) {}"#)
        let child = try await CodexStdioFixtures.withChild(command) { child in
            try await CodexStdioFixtures.waitUntil { child.isStopped }
            await child.join()
            var retained = 0
            await #expect(throws: CodexStdioError.capacityExceeded) {
                for try await chunk in child.chunks { retained += chunk.count }
            }
            #expect(retained <= 4 * 4_096)
            return child
        }
        #expect(child.isReaped)
    }
    @Test func discardedStderrCannotBlockOrLeakIntoStdout() async throws {
        let command = CodexStdioFixtures.command(
            #"print STDERR 'invented private diagnostic' x 100000; print "ready\n"; while(<STDIN>) {}"#)
        let child = try await CodexStdioFixtures.withChild(command) { child in
            let output = try await CodexStdioFixtures.firstChunk(child)
            #expect(output == Data("ready\n".utf8))
            return child
        }
        #expect(child.isReaped)
    }
    @Test func spawnAndConfigurationFailuresAreFixed() {
        #expect(throws: CodexStdioError.transportLost) {
            try OwnedStdioChild(command: OwnedStdioCommand(executable: "/no-such-public-test-command"))
        }
        #expect(throws: CodexStdioError.invalidConfiguration) {
            try OwnedStdioChild(command: OwnedStdioCommand(executable: "perl"))
        }
    }
}
#endif
