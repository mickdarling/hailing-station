#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension CodexStdioTransportTests {
    @Test func prematureReplyCannotCancelBlockedWriteDeadlineOrForgeSuccess() async throws {
        try await blockedWrite(notification: false)
    }
    @Test func notificationOnlyBlockedWriteKeepsDeadlineAndReaps() async throws {
        try await blockedWrite(notification: true)
    }
    @Test func prematureReplyCannotHideBrokenPipeWriteFailure() async throws {
        let command = CodexStdioFixtures.command(
            #"close STDIN; print "{\"id\":1,\"result\":null}\n"; while(1) {}"#)
        var limits = CodexStdioLimits(); limits.requestTimeout = .seconds(60)
        let empty: JSONValue = .object(["id": .integer(1), "method": .string("initialize"), "params": .string("")])
        let overhead = try JSONEncoder().encode(empty).count
        let params = JSONValue.string(String(repeating: "x", count: limits.maxFrameBytes - overhead))
        let transport = try await CodexStdioTransport.withTransport(command: command, limits: limits) { transport in
            try await CodexStdioFixtures.withSafety(transport) {
                await #expect(throws: CodexStdioError.transportLost) {
                    try await transport.request(.initialize, params: params)
                }
                return ()
            }
            return transport
        }
        #expect(await transport.isReaped)
    }
    private func blockedWrite(notification: Bool) async throws {
        // Warm up explicitly. select observes the second request's bytes but never consumes them.
        let code = #"$SIG{TERM}='IGNORE'; print "{\"method\":\"ready\"}\n"; "# +
            #"$_=<STDIN>; /"id":(\d+)/ or die; "# +
            #"print "{\"id\":$1,\"result\":null}\n"; $readable=''; vec($readable,fileno(STDIN),1)=1; "# +
            #"select($readable,undef,undef,undef); "# +
            (notification ? "" : #"print "{\"id\":2,\"result\":null}\n"; "#) +
            #"print "{\"method\":\"blocked-proof\"}\n"; while(1) {}"#
        var limits = CodexStdioLimits(); limits.requestTimeout = .seconds(1); limits.terminationGrace = 0.02
        var object: [String: JSONValue] = ["method": .string(notification ? "initialized" : "thread/start"),
                                          "params": .string("")]
        if !notification { object["id"] = .integer(2) }
        let overhead = try JSONEncoder().encode(JSONValue.object(object)).count
        let params = JSONValue.string(String(repeating: "x", count: limits.maxFrameBytes - overhead))
        let transport = try await CodexStdioTransport.withTransport(
            command: CodexStdioFixtures.command(code), limits: limits) { transport in
            try await CodexStdioFixtures.withSafety(transport) {
                let ready = try await transport.nextNotification()
                #expect(ready.method == "ready")
                #expect(try await transport.request(.initialize) == .null)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await #expect(throws: CodexStdioError.timedOut) {
                            if notification { try await transport.notify(.initialized, params: params) } else {
                                _ = try await transport.request(.threadStart, params: params)
                            }
                        }
                    }
                    defer { transport.cancel(); group.cancelAll() }
                    let notice = try await transport.nextNotification()
                    #expect(notice.method == "blocked-proof") // The early reply/write condition actually occurred.
                    try await group.waitForAll()
                }
            }
            return transport
        }
        #expect(await transport.isReaped)
    }
}
#endif
