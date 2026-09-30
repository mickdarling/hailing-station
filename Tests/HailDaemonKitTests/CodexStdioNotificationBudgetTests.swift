#if os(macOS)
import Testing
@testable import HailDaemonKit

extension CodexStdioTransportTests {
    @Test(arguments: [false, true]) func notificationByteBudgetDoesNotDependOnWaitingConsumer(waiting: Bool)
        async throws {
        let code = #"$count=0; while(<STDIN>) { /"id":(\d+)/ or die; $count++; if($count==1) { "# +
            #"print "{\"id\":$1,\"result\":null}\n"; } else { "# +
            #"print "{\"method\":\"budget\",\"params\":\"", 'x' x 128, "\"}\n"; } }"#
        var limits = CodexStdioLimits(); limits.maxNotificationBytes = 64
        let transport = try await CodexStdioTransport.withTransport(
            command: CodexStdioFixtures.command(code), limits: limits) { transport in
            try await CodexStdioFixtures.withSafety(transport) {
                #expect(try await transport.request(.initialize) == .null)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { transport.cancel(); group.cancelAll() }
                    if waiting {
                        group.addTask {
                            await #expect(throws: CodexStdioError.capacityExceeded) {
                                try await transport.nextNotification()
                            }
                        }
                        try await CodexStdioFixtures.waitUntil { await transport.isWaitingForNotification }
                    }
                    await #expect(throws: CodexStdioError.capacityExceeded) {
                        try await transport.request(.threadStart)
                    }
                    if !waiting {
                        await #expect(throws: CodexStdioError.capacityExceeded) {
                            try await transport.nextNotification()
                        }
                    }
                    try await group.waitForAll()
                }
            }
            return transport
        }
        #expect(await transport.isReaped)
    }
}
#endif
