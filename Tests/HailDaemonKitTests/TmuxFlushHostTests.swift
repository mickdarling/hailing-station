import Testing
@testable import HailDaemonKit

/// #894 ask 1: a prompt flush is gated as `escape` is: allowed, bound, not rebound, not locked, no lockdown, a usable
/// policy. A denial reads nothing from the pane and sends nothing. Scripted runner, in-memory policy.
@Suite struct TmuxFlushHostTests {
    private let id = "tmux:claude-hail"

    private func host(_ harness: FlushHarness, tier: Tier = .confirm, binding: String = FlushHarness.binding)
        async throws -> HailHost {
        let registry = Registry()
        try await registry.register(harness.adapter)
        var policy = Policy()
        try policy.allow(id, binding: binding, tier: tier)
        return try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
    }

    @Test func anAllowedTargetAtTheConfirmTierIsReadAndCleared() async throws {
        let harness = FlushHarness(FlushPane("ZULIP"))
        let host = try await host(harness)
        let draft = try await host.promptDraft(id)
        #expect(draft.text == "ZULIP")
        let result = try await host.flushPrompt(id, expecting: draft)
        #expect(result.isEmpty && result.clearedCharacters == 5)
        await harness.expectNoInterrupt()
    }

    @Test func everyEscapeDenialAlsoRefusesAFlushBeforeAnyLook() async throws {
        let draft = try FlushPane.sampleDraft()
        struct Case { let tier: Tier, binding: String, lockdown: Bool, denial: HostError }
        let cases = [
            Case(tier: .locked, binding: FlushHarness.binding, lockdown: false, denial: .denied(.locked(id))),
            Case(tier: .confirm, binding: "$1@1758230000/%1:999", lockdown: false, denial: .denied(.rebound(id))),
            Case(tier: .open, binding: FlushHarness.binding, lockdown: true, denial: .denied(.lockdown))
        ]
        for item in cases {
            let denial = item.denial
            let harness = FlushHarness(FlushPane("ZULIP"))
            let host = try await host(harness, tier: item.tier, binding: item.binding)
            if item.lockdown { _ = await host.engageLockdown(reason: "synthetic") }
            await #expect(throws: denial) { _ = try await host.promptDraft(id) }
            await #expect(throws: denial) { _ = try await host.flushPrompt(id, expecting: draft) }
            #expect(await harness.runner.calls.allSatisfy { $0.contains("list-sessions") }, "\(denial)")
            #expect(harness.pane.keys.isEmpty)
        }
        // A target that was never allowed.
        let harness = FlushHarness(FlushPane("ZULIP"))
        let registry = Registry()
        try await registry.register(harness.adapter)
        let open = try HailHost(registry: registry, store: InMemoryPolicyStore(Policy()))
        await #expect(throws: HostError.denied(.notAllowed(id))) {
            _ = try await open.flushPrompt(id, expecting: draft)
        }
        #expect(harness.pane.keys.isEmpty)
    }

    @Test func aNonTmuxTargetIsRefused() async throws {
        let registry = Registry()
        try await registry.register(FakeAdapter(kind: "console", targets: [AdapterTarget(name: "a", binding: "b1")]))
        var policy = Policy()
        try policy.allow("console:a", binding: "b1", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        await #expect(throws: AdapterError.deliveryFailed("a prompt flush is for tmux targets only")) {
            _ = try await host.promptDraft("console:a")
        }
    }
}

extension FlushPane {
    /// A draft as a preview would have read it, for calls a denial stops first.
    static func sampleDraft() throws -> TmuxPromptDraft {
        try PaneObservation(rows: ["❯ ZULIP"], cursorX: 7, cursorY: 0, width: 80).promptDraft()
    }
}
