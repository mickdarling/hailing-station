import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #200: a local dispatch is sanitised under the local RightyO prompt cap, phone text frames keep the default
/// cap, and every other gate (guard, tier, lockdown) gives the direct path's outcome. Synthetic text only.
@Suite struct LocalDispatchCapTests {
    private static let target = "tmux:reply"
    /// A RightyO request carrying about 1 MiB of context: far past 2,000 characters, inside 1,200,000.
    private static let mebibytePrompt = String(repeating: "a", count: 1 << 20)
    /// Past the default 2,000-character cap, short enough that the default guard rules finish in budget.
    private static let guardedPrompt = String(repeating: "a", count: 3_000) + " sudo rm -rf /"

    private struct Rig {
        let host: HailHost
        let adapter: FakeAdapter
        let session: HostSession
    }

    private func dispatchSession(tier: Tier = .open, guards: [GuardPattern]? = nil) async throws -> Rig {
        // The anchored guard keeps a 1 MiB prompt deterministic; the default rules have their own suites.
        var policy = Policy(
            guardPatterns: guards ?? [.init(name: "synthetic guard", regex: "^synthetic guarded command$")]
        )
        try policy.allow(Self.target, binding: "binding", tier: tier)
        let (host, adapter) = try await sessionHost(
            targets: [AdapterTarget(name: "reply", binding: "binding")], policy: policy
        )
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        return Rig(host: host, adapter: adapter, session: session)
    }

    private func request(_ text: String) -> LocalDispatchRequest {
        dispatchRequest(connection: UUID(), target: Self.target, binding: "binding", text: text)
    }

    @Test func capIsTheDirectRightyoPolicyAndTheDefaultStaysForPhones() {
        #expect(HailHost.localPromptSanitizing == SanitizePolicy(maxCharacters: 1_200_000, maxUTF8Bytes: 1_200_000))
        #expect(LocalDispatchRequest.maxTextBytes == HailHost.localPromptSanitizing.maxUTF8Bytes)
        #expect(SanitizePolicy() == SanitizePolicy(maxCharacters: 2_000, maxUTF8Bytes: 8_192))
    }

    @Test func mebibyteDispatchIsDeliveredWhileAPhoneFrameOverTheDefaultCapIsRefused() async throws {
        let rig = try await dispatchSession()
        let (adapter, session) = (rig.adapter, rig.session)
        #expect(try await session.dispatch(request(Self.mebibytePrompt)) == nil)
        let delivered = await adapter.deliveries
        try #require(delivered.count == 1)
        #expect(delivered[0].text.utf8.count == 1 << 20)
        // After the dispatch, on the same session and host, a phone frame keeps the 2,000-character cap.
        let phone = sessionFrame(
            target: Self.target, payload: .text(TextPayload(text: String(repeating: "b", count: 2_001)))
        )
        let result = await session.receive(phone)
        guard case .control(.error(_, let message)) = try #require(result.frames.first).payload else {
            Issue.record("phone frame over the default cap was not refused")
            return
        }
        #expect(message == "target action was refused")
        #expect(await adapter.deliveries.count == 1)
        // The same text as a dispatch is delivered: only the ingress decides the cap.
        _ = try await session.dispatch(request(String(repeating: "b", count: 2_001)))
        #expect(await adapter.deliveries.count == 2)
    }

    @Test func dispatchOverTheLocalPromptCapIsStillRefused() async throws {
        let rig = try await dispatchSession()
        let (adapter, session) = (rig.adapter, rig.session)
        let over = String(repeating: "a", count: HailHost.localPromptSanitizing.maxCharacters + 1)
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await session.dispatch(request(over)) }
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func defaultGuardFiresOnALargeDispatchExactlyAsOnTheDirectPath() async throws {
        let rig = try await dispatchSession(guards: DangerousPatternGuard.defaults)
        let (adapter, session) = (rig.adapter, rig.session)
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
            try await session.dispatch(request(Self.guardedPrompt))
        }
        #expect(await adapter.deliveries.isEmpty)
        // The direct `haild rightyo` host (local-prompt policy, no dispatch scope) reaches the same decision.
        var policy = Policy()
        try policy.allow(Self.target, binding: "binding", tier: .open)
        let registry = Registry()
        let direct = FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "reply", binding: "binding")])
        try await registry.register(direct)
        let host = try HailHost(
            registry: registry, sanitizing: HailHost.localPromptSanitizing, store: InMemoryPolicyStore(policy)
        )
        guard case .needsConfirmation = try await host.send(Self.guardedPrompt, to: Self.target) else {
            Issue.record("direct path did not require confirmation")
            return
        }
        #expect(await direct.deliveries.isEmpty)
    }

    @Test func lockedTierAndLockdownRefuseALargeDispatch() async throws {
        let locked = try await dispatchSession(tier: .locked)
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
            try await locked.session.dispatch(request(Self.mebibytePrompt))
        }
        #expect(await locked.adapter.deliveries.isEmpty)
        let rig = try await dispatchSession()
        _ = await rig.host.engageLockdown(reason: "synthetic")
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
            try await rig.session.dispatch(request(Self.mebibytePrompt))
        }
        #expect(await rig.adapter.deliveries.isEmpty)
    }
}
