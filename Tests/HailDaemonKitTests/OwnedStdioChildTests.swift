#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct OwnedStdioChildTests {
    @Test func actualPipesEchoAndReapedCleanup() async throws {
        let child = try OwnedStdioChild(command: CodexStdioFixtures.echo)
        try await child.write(Data("{\"id\":1}\n".utf8))
        let result = try await CodexStdioFixtures.firstChunk(child)
        #expect(String(data: result, encoding: .utf8) == "{\"id\":1,\"result\":{\"ok\":true}}\n")
        child.cancel(); child.cancel(); await child.join()
        #expect(child.isReaped)
        await #expect(throws: CodexStdioError.stopped) { try await child.write(Data([10])) }
    }
    @Test func ignoredSIGTERMEscalatesAndActuallyReaps() async throws {
        let command = CodexStdioFixtures.command(
            #"$SIG{TERM}='IGNORE'; print "ready\n"; while(1) { select undef,undef,undef,1; }"#)
        let child = try OwnedStdioChild(command: command, grace: 0.02)
        let ready = try await CodexStdioFixtures.firstChunk(child)
        #expect(ready == Data("ready\n".utf8))
        let began = ContinuousClock().now
        child.cancel(); await child.join()
        #expect(child.isReaped)
        #expect(began.duration(to: .now) < .seconds(2))
    }
    @Test func nonReadingChildWriteCancellationUnblocksAndReaps() async throws {
        let child = try OwnedStdioChild(command: CodexStdioFixtures.command(
            #"$SIG{TERM}='IGNORE'; print "ready\n"; while(1) { select undef,undef,undef,1; }"#), grace: 0.02)
        _ = try await CodexStdioFixtures.firstChunk(child)
        let write = Task { try await child.write(Data(repeating: 65, count: 65_537)) }
        await Task.yield()
        child.cancel(); await child.join()
        await #expect(throws: CodexStdioError.stopped) { try await write.value }
        #expect(child.isReaped)
    }
    @Test func closedPipeDoesNotRaiseSIGPIPEOrExposeErrno() async throws {
        let child = try OwnedStdioChild(command: CodexStdioFixtures.command(
            #"close STDIN; print "ready\n"; while(1) { select undef,undef,undef,1; }"#))
        _ = try await CodexStdioFixtures.firstChunk(child)
        await #expect(throws: CodexStdioError.transportLost) { try await child.write(Data([65])) }
        await child.join(); #expect(child.isReaped)
    }
    @Test func chunkOverflowCancelsAndReapsWithoutUnboundedRetention() async throws {
        let child = try OwnedStdioChild(command: CodexStdioFixtures.command(#"print 'x' x 100000; while(1) {}"#))
        try await CodexStdioFixtures.waitUntil { child.isStopped }
        await child.join(); #expect(child.isReaped)
        var retained = 0
        do { for try await chunk in child.chunks { retained += chunk.count } } catch {
            #expect(error as? CodexStdioError == .capacityExceeded)
        }
        #expect(retained <= 4 * 4_096)
    }
    @Test func discardedStderrCannotBlockOrLeakIntoStdout() async throws {
        let child = try OwnedStdioChild(command: CodexStdioFixtures.command(
            #"print STDERR 'invented private diagnostic' x 100000; print "ready\n"; while(<STDIN>) {}"#))
        let output = try await CodexStdioFixtures.firstChunk(child)
        #expect(output == Data("ready\n".utf8))
        child.cancel(); await child.join(); #expect(child.isReaped)
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
