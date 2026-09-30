#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

extension CodexStdioTransportTests {
    @Test func outstandingAdmissionUsesExplicitReadinessNotTimeoutTiming() async throws {
        var limits = CodexStdioLimits(); limits.maxRequests = 1; limits.requestTimeout = .seconds(60)
        let command = CodexStdioFixtures.command(
            #"$_=<STDIN>; print "{\"method\":\"ready\"}\n"; while(<STDIN>) {}"#)
        let transport = try await CodexStdioTransport.withTransport(command: command, limits: limits) { transport in
            try await CodexStdioFixtures.withSafety(transport) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await #expect(throws: CodexStdioError.stopped) { try await transport.request(.initialize) }
                    }
                    defer { transport.cancel(); group.cancelAll() }
                    let notice = try await transport.nextNotification()
                    #expect(notice.method == "ready")
                    await #expect(throws: CodexStdioError.capacityExceeded) {
                        try await transport.request(.threadStart)
                    }
                    transport.cancel()
                }
            }
            return transport
        }
        #expect(await transport.isReaped)
    }
    @Test func silentRequestTimeoutDoesNotRequireChildReadiness() async throws {
        var limits = CodexStdioLimits(); limits.requestTimeout = .milliseconds(50)
        let command = CodexStdioFixtures.command(#"while(<STDIN>) {}"#)
        let transport = try await CodexStdioTransport.withTransport(command: command, limits: limits) { transport in
            let safety = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                transport.cancel()
            }
            await #expect(throws: CodexStdioError.timedOut) { try await transport.request(.initialize) }
            safety.cancel(); await safety.value
            return transport
        }
        #expect(await transport.isReaped)
    }
}
#endif
