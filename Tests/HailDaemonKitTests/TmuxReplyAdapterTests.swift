import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct TmuxReplyAdapterTests {
    @Test func absentConfigurationIsOffAndEmptyProfileDoesNotList() async throws {
        #expect(try TmuxReplyAdapter.configuredTargets(in: [:]).isEmpty)
        #expect(try TmuxReplyAdapter.configuredTargets(in: [TmuxReplyAdapter.configurationVariable: "[]"]).isEmpty)
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing))
        let adapter = try TmuxReplyAdapter(terminal: TmuxAdapter(runner: runner), targets: [])
        #expect(try await adapter.listTargets().isEmpty)
        #expect(await runner.calls.isEmpty)
    }

    @Test func configurationIsExplicitBoundedAndDoesNotGuessNames() throws {
        #expect(try TmuxReplyAdapter.configuredTargets(in: [
            TmuxReplyAdapter.configurationVariable: #"["bridge", "other-bridge"]"#
        ]) == ["bridge", "other-bridge"])
        let oversized = String(repeating: "x", count: ReplyLimits.maxIdentifierBytes + 1)
        let tooMany = (0...TmuxReplyAdapter.maxConfiguredTargets).map { "bridge-\($0)" }
        let tooManyJSON = try #require(String(data: try JSONEncoder().encode(tooMany), encoding: .utf8))
        for value in ["", "bridge", "null", #"["bridge", "bridge"]"#, #"[""]"#, #"["   "]"#,
                      #"["bridge\nother"]"#, #"["bridge\u0000"]"#, #"["bridge\u2028other"]"#,
                      "[\"\(oversized)\"]", tooManyJSON] {
            #expect(throws: TmuxReplyAdapterError.invalidConfiguration) {
                try TmuxReplyAdapter.configuredTargets(in: [TmuxReplyAdapter.configurationVariable: value])
            }
        }
    }

    @Test func listingExposesOnlyExplicitBridgeTargetsAndKeepsOpaqueBinding() async throws {
        let rig = try BridgeRig()
        #expect(try await rig.adapter.listTargets() == [AdapterTarget(name: "bridge", binding: bridgeBinding)])
        #expect(rig.adapter.kind == "tmux-reply")
        #expect(rig.adapter.inputShape == .singleLineContextual)
    }

    @Test func envelopePreservesRequestOutsideTextWithoutConnectionOrPrivateBinding() async throws {
        let rig = try BridgeRig()
        let text = #"synthetic "quoted" input \ ; $(x) `y`"#
        try await rig.adapter.deliver(text, to: "bridge", binding: bridgeBinding, context: rig.context)
        let envelope = try await submittedEnvelope(on: rig.runner)
        #expect(envelope.version == 1)
        #expect(envelope.request == rig.context.id)
        #expect(envelope.text == text)
        let line = await literalChunks(on: rig.runner).joined()
        let fields = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(fields.keys) == ["version", "request", "text"])
        #expect(!line.contains(bridgeBinding))
        #expect(!line.contains(rig.context.connectionID.uuidString))
    }

    @Test func legacyBridgeInputRefusesBeforeAnyTerminalOperation() async throws {
        let rig = try BridgeRig()
        await #expect(throws: TmuxReplyAdapterError.contextRequired) {
            try await rig.adapter.deliver("synthetic input", to: "bridge", binding: bridgeBinding)
        }
        #expect(await rig.runner.calls.isEmpty)
    }

    @Test func unconfiguredTargetAndWrongContextRefuseBeforeAnyTerminalOperation() async throws {
        let rig = try BridgeRig()
        await #expect(throws: AdapterError.unknownTarget("ordinary")) {
            try await rig.adapter.deliver("synthetic input", to: "ordinary", binding: bridgeBinding,
                                          context: rig.context)
        }
        for (provider, target, binding) in [
            ("tmux", "tmux-reply:bridge", bridgeBinding),
            ("tmux-reply", "tmux-reply:ordinary", bridgeBinding),
            ("tmux-reply", "tmux-reply:bridge", "different-binding")
        ] {
            let wrong = try bridgeContext(provider: provider, target: target, binding: binding)
            await #expect(throws: ProviderContractError.wrongContext) {
                try await rig.adapter.deliver("synthetic input", to: "bridge", binding: bridgeBinding,
                                              context: wrong)
            }
        }
        #expect(await rig.runner.calls.isEmpty)
    }

    @Test func invalidOrOversizedTextRefusesBeforeAnyTerminalOperation() async throws {
        let rig = try BridgeRig()
        for text in ["", "   ", "one\ntwo", String(repeating: "x", count: PayloadLimits.maxTextBytes + 1)] {
            await #expect(throws: TmuxReplyAdapterError.invalidText) {
                try await rig.adapter.deliver(text, to: "bridge", binding: bridgeBinding, context: rig.context)
            }
        }
        #expect(await rig.runner.calls.isEmpty)
    }

    @Test func reboundPaneNeverReceivesEnvelope() async throws {
        let rig = try BridgeRig(listing: "$8|1758230000|%8|808|bridge\n")
        await #expect(throws: AdapterError.rebound("bridge")) {
            try await rig.adapter.deliver("synthetic input", to: "bridge", binding: bridgeBinding,
                                          context: rig.context)
        }
        #expect(await literalChunks(on: rig.runner).isEmpty)
    }

    @Test func paneSwitchBeforeEnterNeverExecutesEnvelope() async throws {
        let counter = SessionListing("0")
        let runner = FakeCommandRunner { arguments in
            guard arguments.contains("list-sessions") else { return CommandResult(exitCode: 0, stdout: "") }
            let count = Int(counter.get()) ?? 0
            counter.set(String(count + 1))
            return CommandResult(exitCode: 0, stdout: count == 0 ? bridgeListing : "$1|1758230000|%8|808|bridge\n")
        }
        let adapter = try TmuxReplyAdapter(
            terminal: TmuxAdapter(runner: runner, pollInterval: nil), targets: ["bridge"]
        )
        await #expect(throws: AdapterError.rebound("bridge")) {
            try await adapter.deliver("synthetic input", to: "bridge", binding: bridgeBinding,
                                     context: bridgeContext())
        }
        #expect(await runner.calls.filter { $0.last == "Enter" }.isEmpty)
    }

    @Test func ordinaryTmuxInputRemainsLiteralAndContextUnsupported() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing))
        let terminal = TmuxAdapter(runner: runner, pollInterval: nil)
        let input = #"synthetic "input" $(x)"#
        try await terminal.deliver(input, to: "ordinary", binding: "$2@1758230001/%2:502")
        #expect(await literalChunks(on: runner) == [input])
        let registry = Registry()
        try await registry.register(terminal)
        let context = try bridgeContext(provider: "tmux", target: "tmux:ordinary", binding: "$2@1758230001/%2:502")
        await #expect(throws: RegistryError.contextualDeliveryUnsupported) {
            try await registry.requireInputDelivery(to: "tmux:ordinary", context: context, lineCount: 1)
        }
    }

    @Test func adapterDoesNotGrantCaptureOrUnboundEscape() async throws {
        let rig = try BridgeRig()
        await #expect(throws: AdapterError.captureFailed("reply bridge does not support capture")) {
            try await rig.adapter.capture("bridge")
        }
        await #expect(throws: ProviderContractError.wrongContext) {
            try await rig.adapter.escape("bridge", binding: nil)
        }
        #expect(await rig.runner.calls.isEmpty)
    }
}

extension TmuxReplyAdapterTests {
    @Test func hostSanitizesOriginalTextBeforeEnvelopeAndRequiresSeparatePolicy() async throws {
        let rig = try BridgeRig()
        let registry = Registry()
        try await registry.register(rig.adapter)
        var policy = Policy()
        try policy.allow("tmux:bridge", binding: bridgeBinding, tier: .open)
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, store: store)
        await #expect(throws: HostError.denied(.notAllowed("tmux-reply:bridge"))) {
            try await host.send("synthetic input", context: rig.context)
        }
        #expect(await literalChunks(on: rig.runner).isEmpty)
        _ = try await host.allow("tmux-reply:bridge", tier: .open)
        #expect(try await host.send("\u{1B}[31msynthetic input\u{1B}[0m", context: rig.context) ==
            .delivered(["synthetic input"]))
        #expect(try await submittedEnvelope(on: rig.runner).text == "synthetic input")
    }

    @Test func confirmationLockedAndLockdownNeverSendBridgeEnvelope() async throws {
        let rig = try BridgeRig()
        let registry = Registry()
        try await registry.register(rig.adapter)
        var policy = Policy()
        try policy.allow("tmux-reply:bridge", binding: bridgeBinding, tier: .confirm)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        guard case .needsConfirmation = try await host.send("synthetic input", context: rig.context) else {
            Issue.record("expected confirmation")
            return
        }
        #expect(await literalChunks(on: rig.runner).isEmpty)
        _ = try await host.setTier(.locked, for: "tmux-reply:bridge")
        await #expect(throws: HostError.denied(.locked("tmux-reply:bridge"))) {
            try await host.send("synthetic input", context: rig.context)
        }
        await host.engageLockdown(reason: "synthetic test")
        await #expect(throws: HostError.denied(.lockdown)) {
            try await host.send("synthetic input", context: rig.context)
        }
        #expect(await literalChunks(on: rig.runner).isEmpty)
    }
}
