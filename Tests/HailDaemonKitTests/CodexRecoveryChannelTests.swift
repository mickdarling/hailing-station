#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct CodexRecoveryChannelTests {
    func command(_ body: String) -> OwnedStdioCommand {
        CodexStdioFixtures.command("use JSON::PP; " + body)
    }
    let echo = #"while (<STDIN>) { $v=decode_json($_); delete $v->{op}; $v->{state}='ready'; "#
                + #"$v->{recovered}=JSON::PP::false; print encode_json($v)."\n"; }"#
    @Test func scopedPipeReadyAndCancellationActuallyReap() async throws {
        let channel = try CodexRecoveryChannel(command: command(echo), request: UUID(), generation: UUID())
        do {
            try await channel.send("prepare")
            let ready = try await channel.wait(for: [.ready], until: .now.advanced(by: .seconds(3)))
            #expect(ready.request == channel.request && ready.generation == channel.generation)
            #expect(!ready.recovered)
        } catch { channel.stop(); await channel.join(); throw error }
        channel.stop(); await channel.join()
        #expect(channel.reaped)
        await #expect(throws: CodexRecoveryFault.stopped) { try await channel.send("authorize") }
    }
    @Test(arguments: ["foreign", "partial", "overflow", "extra", "falseRecovery"])
    func invalidOutputRevokesAndReaps(_ variant: String) async throws {
        let bodies = [
            "foreign": #"$_=<STDIN>; $v=decode_json($_); delete $v->{op}; "#
                + #"$v->{request}='00000000-0000-0000-0000-000000000000'; $v->{state}='ready'; "#
                + #"$v->{recovered}=JSON::PP::false; print encode_json($v)."\n";"#,
            "partial": #"print '{';"#,
            "overflow": #"print 'x' x 8193;"#,
            "extra": #"$_=<STDIN>; $v=decode_json($_); $v->{state}='ready'; "#
                + #"$v->{recovered}=JSON::PP::false; print encode_json($v)."\n";"#,
            "falseRecovery": #"$_=<STDIN>; $v=decode_json($_); delete $v->{op}; $v->{state}='ready'; "#
                + #"$v->{recovered}=JSON::PP::true; print encode_json($v)."\n";"#
        ]
        let channel = try CodexRecoveryChannel(command: command(try #require(bodies[variant])),
                                                request: UUID(), generation: UUID())
        try? await channel.send("prepare")
        await #expect(throws: (any Error).self) {
            try await channel.wait(for: [.ready], until: .now.advanced(by: .seconds(3)))
        }
        channel.stop(); await channel.join()
        #expect(channel.reaped && channel.report == nil)
    }
    @Test func anIdleWorkerTimeoutIsBoundedAndReaped() async throws {
        let channel = try CodexRecoveryChannel(command: command("while(<STDIN>) {}"),
                                                request: UUID(), generation: UUID())
        try await channel.send("prepare")
        await #expect(throws: CodexRecoveryFault.timeout) {
            try await channel.wait(for: [.ready], until: .now.advanced(by: .milliseconds(50)))
        }
        await channel.join()
        #expect(channel.reaped)
    }
    @Test func terminalProofSurvivesCleanEOFButReadyDoesNot() async throws {
        let body = #"$_=<STDIN>; $v=decode_json($_); delete $v->{op}; $v->{state}='interrupted'; "#
                + #"$v->{recovered}=JSON::PP::true; print encode_json($v)."\n";"#
        let channel = try CodexRecoveryChannel(command: command(body), request: UUID(), generation: UUID())
        try await channel.send("prepare")
        let report = try await channel.wait(for: [.interrupted], until: .now.advanced(by: .seconds(3)))
        #expect(report.recovered)
        await channel.join()
        #expect(channel.reaped)
        channel.stop()
    }
    @Test(arguments: ["{bad}\n", "{"])
    func terminalWithInvalidTrailingOutputNeverGrantsRecovery(_ tail: String) async throws {
        let encoded = try JSONSerialization.data(withJSONObject: [tail])
        let list = try #require(String(data: encoded, encoding: .utf8))
        let body = #"$_=<STDIN>; $v=decode_json($_); delete $v->{op}; $v->{state}='interrupted'; "#
            + #"$v->{recovered}=JSON::PP::true; print encode_json($v)."\n"; "#
            + "print decode_json('" + list + "')->[0];"
        let channel = try CodexRecoveryChannel(command: command(body), request: UUID(), generation: UUID())
        try await channel.send("prepare")
        await #expect(throws: (any Error).self) {
            try await channel.wait(for: [.interrupted], until: .now.advanced(by: .seconds(3)))
        }
        channel.stop(); await channel.join()
        #expect(channel.report == nil && channel.reaped)
    }
    @Test func cancellingASendToANonreadingWorkerRevokesAndReaps() async throws {
        let channel = try CodexRecoveryChannel(command: command("while(1) { select undef,undef,undef,1; }"),
                                                request: UUID(), generation: UUID())
        let safety = Task { try? await Task.sleep(for: .seconds(4)); channel.stop() }
        let send = Task { for _ in 0..<2000 { try await channel.send("prepare") } }
        try await Task.sleep(for: .milliseconds(50))
        let began = ContinuousClock().now
        send.cancel()
        await #expect(throws: (any Error).self) { try await send.value }
        await channel.join()
        #expect(began.duration(to: .now) < .seconds(2))
        #expect(channel.stopped && channel.reaped)
        safety.cancel(); await safety.value
    }
}
#endif
