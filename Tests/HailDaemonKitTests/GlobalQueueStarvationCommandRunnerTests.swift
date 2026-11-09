#if os(macOS)
import Testing
@testable import HailDaemonKit

extension GlobalQueueStarvationTests {
    // OwnedStdioChildCommandRunner deliberately matches OwnedStdioChild for scripts/verify.sh's serial timing lane.
    /// The command runner must drain both pipes and join after exit without a constrained worker (#1156).
    @Suite struct OwnedStdioChildCommandRunner {
        @Test func aCompletedCommandReturnsOnTime() async throws {
            let (result, elapsed) = try await whileGlobalQueueStarved {
                try await ProcessCommandRunner().run("/bin/sh", ["-c", "echo out; echo err >&2"])
            }
            #expect(result.exitCode == 0)
            #expect(result.stdout == "out\n")
            #expect(result.stderr == "err\n")
            #expect(elapsed < GlobalQueueStarvationTests.bound, "command completion took \(elapsed)")
        }
    }
}
#endif
