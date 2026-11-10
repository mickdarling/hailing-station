import Foundation
import Testing
@testable import HailDaemonKit

/// Configuration is not enforcement: the ambient task-local and ordinary send both retain guard holds.
@Suite(.frozenGuardBudget) struct VoiceGuardsAdmissionTests {
    @Test(arguments: [false, true])
    func offStillEscalatesGuardMatches(_ ambient: Bool) async throws {
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "bound")])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: [GuardPattern(name: "synthetic", regex: "guarded-token")], voiceGuards: .off)
        try policy.allow("tmux:a", binding: "bound", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let outcome: SendOutcome
        if ambient {
            let generation = host.targetPolicy.snapshot(for: "tmux:a")
            outcome = try await HostSession.$ambientInputDispatch.withValue(true) {
                try await host.sendAuthorized("guarded-token", policyGeneration: generation, from: "test",
                                              expectedBinding: "bound", context: nil)
            }
        } else {
            outcome = try await host.send("guarded-token", to: "tmux:a")
        }
        guard case .needsConfirmation(let readBack) = outcome else {
            Issue.record("Guard escalation must remain active when configured off")
            return
        }
        #expect(readBack.guardHits == ["synthetic"])
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func malformedSettingOnReloadRefusesDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-voice-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = PolicyFile(directory: directory)
        var policy = Policy(voiceGuards: .off)
        try policy.allow("tmux:a", binding: "bound", tier: .open)
        try file.save(policy)
        let adapter = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "a", binding: "bound")])
        let registry = Registry()
        try await registry.register(adapter)
        let host = try HailHost(registry: registry, store: file)
        try #require(await host.currentPolicy.voiceGuards == .off)
        try Data(#"{"version":1,"voiceGuards":null}"#.utf8).write(to: file.path)
        await #expect(throws: (any Error).self) { try await host.send("ordinary", to: "tmux:a") }
        #expect(await host.policyFailure != nil)
        #expect(await adapter.deliveries.isEmpty)
    }
}
