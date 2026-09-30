#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct CodexStdioTransportTests {
    @Test func initializedNotificationUsesTypedNoIDHandshake() async throws {
        let code = #"while(<STDIN>) { if (/"id":(\d+)/) { "# +
            #"print "{\"id\":$1,\"result\":null}\n"; } else { "# +
            #"print "{\"method\":\"handshake\",\"params\":{\"correct\":"; "# +
            #"print (/initialized/ ? 'true' : 'false'); print "}}\n"; } }"#
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.command(code))
        #expect(try await transport.request(.initialize) == .null)
        try await transport.notify(.initialized)
        #expect(try await transport.nextNotification().params == .object(["correct": .bool(true)]))
        await transport.join(); #expect(await transport.isReaped)
    }
    @Test func prematureReplyCannotCancelBlockedWriteDeadlineOrForgeSuccess() async throws {
        let code = #"$SIG{TERM}='IGNORE'; print "{\"id\":1,\"result\":null}\n"; while(1) {}"#
        try await blockedWrite(code: code, notification: false)
    }
    @Test func notificationOnlyBlockedWriteKeepsDeadlineAndReaps() async throws {
        try await blockedWrite(code: #"$SIG{TERM}='IGNORE'; while(1) {}"#, notification: true)
    }
    @Test func prematureReplyCannotHideBrokenPipeWriteFailure() async throws {
        let command = CodexStdioFixtures.command(
            #"close STDIN; print "{\"id\":1,\"result\":null}\n"; while(1) {}"#)
        var limits = CodexStdioLimits(); limits.requestTimeout = .milliseconds(100)
        let transport = try CodexStdioTransport(command: command, limits: limits)
        let empty: JSONValue = .object(["id": .integer(1), "method": .string("initialize"), "params": .string("")])
        let overhead = try JSONEncoder().encode(empty).count
        let payload = String(repeating: "x", count: limits.maxFrameBytes - overhead)
        await #expect(throws: CodexStdioError.transportLost) {
            try await transport.request(.initialize, params: .string(payload))
        }
        await transport.join(); #expect(await transport.isReaped)
    }
    @Test(arguments: [false, true]) func scopeReturnAndThrowCancelAndJoin(failed: Bool) async throws {
        let command = CodexStdioFixtures.command(#"$SIG{TERM}='IGNORE'; while(<STDIN>) {}"#)
        if failed {
            await #expect(throws: CodexStdioError.providerRefused) {
                try await CodexStdioTransport.withTransport(command: command) { _ in
                    throw CodexStdioError.providerRefused
                }
            }
        } else {
            let transport = try await CodexStdioTransport.withTransport(command: command) { $0 }
            #expect(await transport.isReaped)
        }
    }
    @Test func realPipeRequestAndPreResponseNotification() async throws {
        let command = CodexStdioFixtures.reply(
            #"print "{\"method\":\"turn/started\",\"params\":{\"invented\":true}}\n"; "# +
            #"print "{\"id\":$1,\"result\":null}\n""#)
        let transport = try CodexStdioTransport(command: command)
        #expect(try await transport.request(.initialize) == .null)
        #expect(try await transport.nextNotification() == CodexStdioNotification(
            method: "turn/started", params: .object(["invented": .bool(true)])))
        await CodexStdioFixtures.stopped(transport)
        #expect(await transport.isReaped)
    }
    @Test func reorderedRepliesMatchExactRequestIDs() async throws {
        let code = #"$_=<STDIN>; /"id":(\d+)/; $first=$1; $_=<STDIN>; /"id":(\d+)/; "# +
            #"print "{\"id\":$1,\"result\":$1}\n{\"id\":$first,\"result\":$first}\n"; while(<STDIN>) {}"#
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.command(code))
        let first = Task { try await transport.request(.initialize) }
        await Task.yield()
        let second = Task { try await transport.request(.threadStart) }
        let values = try await [first.value, second.value]
        #expect(values.contains(.integer(1)) && values.contains(.integer(2)))
        await CodexStdioFixtures.stopped(transport)
    }
    @Test(arguments: [
        (#"print "{\"id\":999,\"result\":null}\n""#, CodexStdioError.unknownResponse),
        (#"print "{\"id\":$1,\"method\":\"invented/approval\"}\n""#, .serverRequest),
        (#"print "{\"id\":$1,\"result\":null,\"error\":{}}\n""#, .malformedFrame),
        (#"print "{\"id\":$1,\"id\":$1,\"result\":null}\n""#, .malformedFrame),
        (#"print 'x' x 200"#, .oversizedFrame)
    ]) func invalidInboundClosesAndReaps(scenario: (String, CodexStdioError)) async throws {
        var limits = CodexStdioLimits(); limits.maxFrameBytes = 128
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.reply(scenario.0), limits: limits)
        await #expect(throws: scenario.1) { try await transport.request(.initialize) }
        await transport.join(); #expect(await transport.isReaped)
        await #expect(throws: scenario.1) { try await transport.nextNotification() }
    }
    @Test func providerErrorStringsAreNotReturned() async throws {
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.reply(
            #"print "{\"id\":$1,\"error\":{\"message\":\"invented private content\"}}\n""#))
        await #expect(throws: CodexStdioError.providerRefused) { try await transport.request(.initialize) }
        await CodexStdioFixtures.stopped(transport)
    }
    @Test func timeoutAndOutstandingAdmissionAreBounded() async throws {
        var limits = CodexStdioLimits(); limits.maxRequests = 1; limits.requestTimeout = .milliseconds(50)
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.command(
            #"$_=<STDIN>; print "{\"method\":\"ready\"}\n"; while(<STDIN>) {}"#), limits: limits)
        let first = Task { try await transport.request(.initialize) }
        #expect(try await transport.nextNotification().method == "ready")
        await #expect(throws: CodexStdioError.capacityExceeded) { try await transport.request(.threadStart) }
        await #expect(throws: CodexStdioError.timedOut) { try await first.value }
        await transport.join(); #expect(await transport.isReaped)
    }
    @Test(arguments: [false, true]) func notificationCountAndBytesFailExplicitly(bytes: Bool) async throws {
        var limits = CodexStdioLimits(); limits.maxNotifications = 1
        if bytes { limits.maxNotificationBytes = 1 }
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.reply(
            #"print "{\"method\":\"one\"}\n{\"method\":\"two\"}\n""#), limits: limits)
        await #expect(throws: CodexStdioError.capacityExceeded) { try await transport.request(.initialize) }
        await transport.join(); #expect(await transport.isReaped)
    }
    @Test func cancelledRequestResolvesPendingAndReapsIgnoredTermChild() async throws {
        let command = CodexStdioFixtures.command(
            #"$SIG{TERM}='IGNORE'; $_=<STDIN>; print "{\"method\":\"ready\"}\n"; while(1) {}"#)
        let pair = AsyncStream<CodexStdioTransport>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let request = Task {
            try await CodexStdioTransport.withTransport(command: command) { transport in
                pair.continuation.yield(transport); pair.continuation.finish()
                return try await transport.request(.initialize)
            }
        }
        var iterator = pair.stream.makeAsyncIterator()
        let transport = try #require(await iterator.next())
        #expect(try await transport.nextNotification().method == "ready")
        request.cancel()
        await #expect(throws: CodexStdioError.stopped) { try await request.value }
        #expect(await transport.isReaped) // The scope joins before returning its cancellation error.
    }
    @Test func cancelledNotificationWaiterNeverLeaks() async throws {
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.echo)
        let waiter = Task { try await transport.nextNotification() }
        waiter.cancel()
        await #expect(throws: CodexStdioError.stopped) { try await waiter.value }
        transport.cancel(); await transport.join(); #expect(await transport.isReaped)
    }
    @Test func truncatedEOFAndImmediateEOFRemainFixedFailures() async throws {
        for code in [#"$_=<STDIN>; print '{'"#, #"$_=<STDIN>"#] {
            let transport = try CodexStdioTransport(command: CodexStdioFixtures.command(code))
            let reason: CodexStdioError = code.contains("print") ? .truncatedFrame : .transportLost
            await #expect(throws: reason) { try await transport.request(.initialize) }
            await transport.join(); #expect(await transport.isReaped)
        }
    }
    @Test func invalidOutboundDoesNotWriteOrSpendRequestIdentity() async throws {
        var limits = CodexStdioLimits(); limits.maxFrameBytes = 128
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.echo, limits: limits)
        await #expect(throws: CodexStdioError.oversizedFrame) {
            try await transport.request(.initialize, params: .string(String(repeating: "x", count: 129)))
        }
        #expect(try await transport.request(.initialize) == .object(["ok": .bool(true)]))
        await CodexStdioFixtures.stopped(transport)
    }
}
extension CodexStdioTransportTests {
    @Test func precancelledScopeDoesNotSpawn() async throws {
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CodexStdioTransport.withTransport(
                command: OwnedStdioCommand(executable: "/nonexistent-synthetic-child")) { _ in true }
        }
        await #expect(throws: CodexStdioError.stopped) { try await request.value }
    }
    private func blockedWrite(code: String, notification: Bool) async throws {
        var limits = CodexStdioLimits(); limits.requestTimeout = .milliseconds(50)
        limits.terminationGrace = 0.02
        let transport = try CodexStdioTransport(command: CodexStdioFixtures.command(code), limits: limits)
        var object: [String: JSONValue] = ["method": .string(notification ? "initialized" : "initialize"),
                                           "params": .string("")]
        if !notification { object["id"] = .integer(1) }
        let overhead = try JSONEncoder().encode(JSONValue.object(object)).count
        let params = JSONValue.string(String(repeating: "x", count: limits.maxFrameBytes - overhead))
        let safety = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            transport.cancel()
        }
        let began = ContinuousClock().now
        await #expect(throws: CodexStdioError.timedOut) {
            if notification { try await transport.notify(.initialized, params: params) } else {
                _ = try await transport.request(.initialize, params: params)
            }
        }
        await transport.join(); safety.cancel(); await safety.value
        #expect(await transport.isReaped)
        #expect(began.duration(to: .now) < .seconds(2))
    }
}
#endif
