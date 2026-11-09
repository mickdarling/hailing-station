import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget, .timeLimit(.minutes(1))) struct HostDialogPartialTests {
    private static let blocks = [
        DialogBlock(cause: .known(title: "Computer Use needs macOS permissions"), effects: .none),
        DialogBlock(cause: .known(title: "a dialog"), effects: .pasteMayHaveExecuted),
        DialogBlock(cause: .uninspectable, effects: .enterMayHaveExecuted)
    ]

    @Test(arguments: blocks)
    func firstLineKeepsStructuredError(_ block: DialogBlock) async throws {
        let adapter = DialogPartialAdapter(block: block, failAfter: 0)
        let host = try await host(adapter)
        await #expect(throws: AdapterError.blockedByDialog(block)) {
            try await host.send("one\ntwo", to: "tmux:a")
        }
        #expect(await adapter.delivered.isEmpty)
    }

    @Test(arguments: blocks)
    func laterLineKeepsExactDeliveredLinesAndDialog(_ block: DialogBlock) async throws {
        let adapter = DialogPartialAdapter(block: block, failAfter: 2)
        let host = try await host(adapter)
        let expected = HostError.partial(delivered: ["one", "two"], reason: .dialog(block))
        await #expect(throws: expected) {
            try await host.send("one\ntwo\nthree\nfour", to: "tmux:a")
        }
        #expect(await adapter.delivered == ["one", "two"])
    }

    @Test(arguments: blocks)
    func policyRetirementTakesPrecedence(_ block: DialogBlock) async throws {
        let adapter = DialogPartialAdapter(block: block, failAfter: 1)
        let host = try await host(adapter)
        let generation = host.targetPolicy.snapshot(for: "tmux:a")
        await adapter.beforeFailure { host.targetPolicy.retire("tmux:a") }
        let expected = HostError.partial(delivered: ["one"], reason: "target_policy_changed")
        await #expect(throws: expected) {
            try await host.sendAuthorized(
                "one\ntwo\nthree", policyGeneration: generation, from: "test", expectedBinding: nil, context: nil
            )
        }
        #expect(await adapter.delivered == ["one"])
    }

    @Test(arguments: [
        (DialogBlock.Cause.known(title: "Computer Use needs macOS permissions"),
         "target is blocked by Computer Use needs macOS permissions"),
        (.uninspectable, "target dialog state could not be inspected")
    ], [DialogBlock.Effects.none, .pasteMayHaveExecuted, .enterMayHaveExecuted])
    func cliTextIsPinnedToPR1(cause: DialogBlock.Cause, message: String, effects: DialogBlock.Effects) {
        let block = DialogBlock(cause: cause, effects: effects)
        let reason = HostPartialReason.dialog(block)
        let legacyReason = "deliveryFailed(\"\(message)\")"
        #expect(block.description == message)
        #expect("\(AdapterError.blockedByDialog(block))" == legacyReason)
        #expect(reason.description == legacyReason)
        let partial = HostError.partial(delivered: ["one"], reason: reason)
        let legacyPartial = "partial(delivered: [\"one\"], reason: \(String(reflecting: legacyReason)))"
        #expect("\(partial)" == legacyPartial)
        #expect("\(partial)" == "\(HostError.partial(delivered: ["one"], reason: legacyReason))")
        // This is the CLI's existing interpolation, including its singular-line wording.
        let cli = "delivered 1 line, then: \(reason)"
        #expect(cli == "delivered 1 line, then: \(legacyReason)")
    }

    private func host(_ adapter: DialogPartialAdapter) async throws -> HailHost {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "b1", tier: .open)
        return try HailHost(
            registry: registry, sanitizing: SanitizePolicy(newlines: .split), store: InMemoryPolicyStore(policy)
        )
    }
}

private actor DialogPartialAdapter: Adapter {
    nonisolated let kind = "tmux"
    private let block: DialogBlock
    private let failAfter: Int
    private var onFailure: @Sendable () -> Void = {}
    private(set) var delivered: [String] = []

    init(block: DialogBlock, failAfter: Int) {
        self.block = block
        self.failAfter = failAfter
    }

    func beforeFailure(_ action: @escaping @Sendable () -> Void) { onFailure = action }
    func listTargets() async throws -> [AdapterTarget] { [AdapterTarget(name: "a", binding: "b1")] }
    func capture(_ target: String) async throws -> String { "" }

    func deliver(_ text: String, to target: String, binding: String?) async throws {
        guard delivered.count < failAfter else {
            onFailure()
            throw AdapterError.blockedByDialog(block)
        }
        delivered.append(text)
    }

    func deliver(_ text: String, to target: String, binding: String?, authority: DeliveryAuthority) async throws {
        try authority.requireCurrent()
        try await deliver(text, to: target, binding: binding)
    }
}
