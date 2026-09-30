#if os(macOS)
import Testing
@testable import HailDaemonKit

extension CodexAppServerAdapterTests {
    @Test(arguments: [("auto_review", false), ("guardian_subagent", false), (nil, false), (nil, true)])
    func guardedStartupRefusesUnsupportedEffectiveReviewer(reviewer: (String?, Bool)) async throws {
        let entered = ObservedCounter()
        let command = CodexAppServerFixtures.command(approvalsReviewer: reviewer.0,
                                                     nullApprovalsReviewer: reviewer.1)
        let adapter = try await CodexAppServerAdapter.withOwnedAdapter(
            command: command, verifiedVersion: "0.159.0") { adapter in
            let host = try await CodexAppServerFixtures.host(adapter)
            await #expect(throws: CodexAppServerError.unavailable) {
                try await host.withObservedSession(target: CodexAppServerFixtures.target) { _ in
                    entered.increment()
                }
            }
            #expect(entered.count < 1)
            #expect(await adapter.bufferedEarlyRecords == 0)
            return adapter
        }
        #expect(await adapter.isReaped)
        #expect(try await adapter.listTargets().isEmpty)
    }
}
#endif
