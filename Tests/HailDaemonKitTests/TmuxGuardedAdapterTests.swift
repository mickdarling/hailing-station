import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct TmuxGuardedAdapterTests {
    @Test func retirementAfterListingRefusesBeforeTmuxHandoff() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing))
        let terminal: any Adapter = TmuxAdapter(runner: runner, pollInterval: nil)
        let registry = Registry()
        try await registry.register(terminal)
        let target = "tmux:ordinary"
        var policy = Policy()
        let binding = "$2@1758230001/%2:502"
        try policy.allow(target, binding: binding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let authority: DeliveryAuthority = host.targetPolicy.snapshot(for: target).deliveryAuthority
        let listed = try #require(try await registry.listing().first { $0.info.id == target })
        #expect(listed.binding == binding)
        // Retire after the listing; call the registry directly so only the adapter handoff can refuse.
        #expect(try await host.deny(target))
        _ = try await host.allow(target, tier: .open)
        let before = await runner.calls.count
        await #expect(throws: HostError.denied(.notAllowed(target))) {
            try await registry.deliver("one", to: target, binding: listed.binding, authority: authority)
        }
        #expect(await runner.calls.count == before)
        #expect(await pastedTexts(on: runner).isEmpty)
    }

    @Test(arguments: [false, true])
    func bridgeForwardsAuthorityToCheckedTmuxHandoff(_ retired: Bool) async throws {
        let rig = try BridgeRig()
        let registry = Registry()
        try await registry.register(rig.adapter)
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")])
        try policy.allow("tmux-reply:bridge", binding: bridgeBinding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let generation: TargetPolicyGeneration = host.targetPolicy.snapshot(for: "tmux-reply:bridge")
        if retired {
            #expect(try await host.deny("tmux-reply:bridge"))
            await #expect(throws: HostError.denied(.notAllowed("tmux-reply:bridge"))) {
                try await registry.deliver("one", to: "tmux-reply:bridge", binding: bridgeBinding,
                                           context: rig.context, authority: generation.deliveryAuthority)
            }
            #expect(await rig.runner.calls.isEmpty)
            return
        }
        #expect(try await host.sendAuthorized("one", policyGeneration: generation, from: "test",
                                             expectedBinding: nil, context: rig.context) == .delivered(["one"]))
        let envelope = try await submittedEnvelope(on: rig.runner)
        #expect(envelope.text == "one")
        #expect(envelope.request == rig.context.id)
        #expect(await rig.runner.calls.last?.suffix(1) == ["Enter"])
    }
}
