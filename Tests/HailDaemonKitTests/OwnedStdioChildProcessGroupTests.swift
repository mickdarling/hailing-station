#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct OwnedStdioChildProcessGroupTests {
    @Test func stopKillsTermIgnoringGrandchildAfterLeaderExits() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/owned-stdio-process-group.sh").path
        let command = OwnedStdioCommand(executable: "/bin/sh", arguments: [fixture], ownProcessGroup: true)
        try await CodexStdioFixtures.withChild(command, grace: 0.5) { child in
            let ready = try await CodexStdioFixtures.firstChunk(child)
            let text = try #require(String(data: ready, encoding: .utf8))
            let ids = text.split(whereSeparator: { $0.isWhitespace })
                .compactMap { Int32($0) }
            #expect(ids.count == 2)
            let group = try #require(ids.first)
            let grandchild = try #require(ids.last)
            #expect(group > 1 && group != getpgrp())
            guard group > 1, group != getpgrp() else { return }
            defer { _ = kill(-group, SIGKILL) } // Failure cleanup is bounded too.
            #expect(getpgid(grandchild) == group)
            #expect(kill(grandchild, 0) == 0)
            child.cancel()
            // Cleanup must work regardless of when waitpid observes the leader's TERM exit.
            try await CodexStdioFixtures.waitUntil { child.isReaped }
            await child.join()
            try await CodexStdioFixtures.waitUntil { kill(-group, 0) == -1 && errno == ESRCH }
            #expect(kill(grandchild, 0) == -1 && errno == ESRCH)
        }
    }

    @Test func defaultCommandStillInheritsParentGroup() async throws {
        let command = CodexStdioFixtures.command(#"print getpgrp()."\n"; while(<STDIN>) {}"#)
        #expect(!command.ownProcessGroup)
        try await CodexStdioFixtures.withChild(command) { child in
            let ready = try await CodexStdioFixtures.firstChunk(child)
            let text = try #require(String(data: ready, encoding: .utf8))
            let group = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(group == getpgrp())
        }
    }
}
#endif
