import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct VoiceGuardsPreservedGatesTests {
    enum Gate: CaseIterable { case confirm, locked, lockdown, binding, allowlist }

    @Test(arguments: Gate.allCases)
    func ambientOffPreservesPolicyGates(_ gate: Gate) async throws {
        let adapter = FinalDeliveryAdapter(), route = try await VoiceGuardsRoute.make(adapter: adapter)
        switch gate {
        case .confirm: _ = try await route.host.setTier(.confirm, for: route.target)
        case .locked: _ = try await route.host.setTier(.locked, for: route.target)
        case .lockdown: _ = await route.host.engageLockdown(reason: "synthetic test")
        case .binding: route.setPolicy { $0.targets[route.target]?.binding = "changed-binding" }
        case .allowlist: _ = try await route.host.deny(route.target)
        }
        if gate == .confirm {
            await #expect(throws: LocalDispatchRefusal.confirmationRequired) { try await route.ambient() }
        } else {
            await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await route.ambient() }
        }
        #expect(await adapter.deliveries.isEmpty)
        #expect(route.log.lines.isEmpty)
        await route.listener.stop()
    }

    @Test func ambientOffStillSpendsAndEnforcesTheRateBudget() async throws {
        let adapter = FinalDeliveryAdapter()
        let route = try await VoiceGuardsRoute.make(adapter: adapter,
            policy: Policy(guardPatterns: [VoiceGuardsRoute.rule], deliveriesPerMinute: 1, voiceGuards: .off))
        _ = try await route.ambient()
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await route.ambient() }
        #expect(await adapter.deliveries == [VoiceGuardsRoute.words])
        #expect(route.log.lines.count == 1)
        await route.listener.stop()
    }

    @Test func theRealTmuxDialogVetoStillRefusesBeforePaste() async throws {
        let harness = DialogSubmissionFixture(.beforePaste).harness()
        let route = try await VoiceGuardsRoute.make(adapter: harness.adapter, target: "tmux:codex",
                                                   binding: "$2@1758230001/%2:502")
        await #expect(throws: LocalDispatchRefusal.blockedByDialog(.init(
            cause: .known(.computerUsePermissions), effects: .none), earlierDelivered: 0)) { try await route.ambient() }
        #expect(await harness.keys.isEmpty)
        let calls = await harness.runner.calls
        #expect(calls.contains { $0.contains("set-buffer") })
        #expect(!calls.contains { $0.contains("paste-buffer") || $0.contains("send-keys") })
        #expect(route.log.lines.count == 1, "guard suppression is recorded even when a later adapter gate refuses")
        await route.listener.stop()
    }

    @Test func theRealTmuxPendingInputCheckStillRefusesBeforePaste() async throws {
        let pane = ScriptedPane(baseline: "> synthetic guarded command▌")
        let runner = FakeCommandRunner { pane.respond($0) }
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: EvidenceHarness.timing(),
                                  submitClock: ManualSubmitClock().clock)
        let route = try await VoiceGuardsRoute.make(adapter: adapter, target: "tmux:codex",
                                                   binding: "$2@1758230001/%2:502")
        await #expect(throws: LocalDispatchRefusal.inputPending) { try await route.ambient() }
        #expect(await runner.delivered.isEmpty)
        #expect(await runner.calls.allSatisfy { !$0.contains("paste-buffer") && !$0.contains("send-keys") })
        #expect(route.log.lines.count == 1)
        await route.listener.stop()
    }

    @Test func retired1173AdmissionStillRefusesAtTheFinalAdapterCheck() async throws {
        let adapter = FinalDeliveryAdapter(), route = try await VoiceGuardsRoute.make(adapter: adapter)
        await adapter.handoff.arm()
        let sending = Task { try await route.ambient() }
        await adapter.handoff.wait()
        await route.peer.finish(reason: "synthetic retirement")
        await adapter.handoff.resume()
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await sending.value }
        #expect(await adapter.deliveries.isEmpty)
        #expect(await route.session.replyRequests.isEmpty)
        #expect(route.log.lines.count == 1)
        await route.listener.stop()
    }
}
