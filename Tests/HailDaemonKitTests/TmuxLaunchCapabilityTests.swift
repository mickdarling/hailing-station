import Testing
@testable import HailDaemonKit

@Suite struct TmuxLaunchCapabilityTests {
    private actor CheckRunner: CommandRunner {
        var calls: [[String]] = []
        func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
            calls.append(arguments)
            let output = arguments.contains("list-sessions") ? twoSessions : ""
            return CommandResult(exitCode: 0, stdout: output)
        }
    }

    @Test func runnerWithoutLaunchSupportRefusesGuardedPaste() async throws {
        let runner = CheckRunner()
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let authority = DeliveryAuthority(admission: DeliveryAdmission(gates: [:]))
        await #expect(throws: DeliveryAdmissionError.unsupported) {
            try await adapter.deliver("synthetic input", to: "codex", binding: nil, authority: authority)
        }
        let calls = await runner.calls
        #expect(!calls.contains { $0.contains("paste-buffer") || $0.contains("send-keys") })
        #expect(calls.last?.contains("delete-buffer") == true)
        try await adapter.deliver("clean input", to: "codex", binding: nil)
    }

    @Test func checkOnlyAuthorityCannotAdmitAPaste() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(twoSessions))
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        await #expect(throws: DeliveryAdmissionError.unsupported) {
            try await adapter.deliver("synthetic input", to: "codex", binding: nil, authority: DeliveryAuthority {})
        }
        #expect(await runner.delivered.isEmpty)
        try await adapter.deliver("clean input", to: "codex", binding: nil)
        #expect(await runner.delivered == ["clean input", "Enter"])
    }
}
