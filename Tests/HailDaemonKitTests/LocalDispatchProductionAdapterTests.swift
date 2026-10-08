import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #200 end to end on the daemon's production adapters (`haild run` registers `TmuxAdapter` and, when
/// configured, `TmuxReplyAdapter`), driven by a scripted command runner: no tmux process is spawned.
@Suite struct LocalDispatchProductionAdapterTests {
    private static let binding = "$2@1758230001/%2:502"

    private func session(_ registry: Registry, allowing target: String, binding: String) async throws -> HostSession {
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")])
        try policy.allow(target, binding: binding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return session
    }

    @Test func mebibyteDispatchReachesATmuxPaneWhole() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing))
        let registry = Registry()
        try await registry.register(TmuxAdapter(runner: runner, pollInterval: nil))
        let session = try await session(registry, allowing: "tmux:ordinary", binding: Self.binding)
        let text = String(repeating: "a", count: 1 << 20)
        let request = LocalDispatchRequest(
            connection: UUID(), target: "tmux:ordinary", binding: Self.binding, text: text
        )
        // Generic tmux input owns no reply: delivered, `request: null`, exactly as on the direct path.
        #expect(try await session.dispatch(request) == nil)
        #expect(await pastedTexts(on: runner).joined() == text)
        #expect(await runner.calls.last?.suffix(1) == ["Enter"])
        // A phone frame over the default cap still never reaches the pane.
        let before = await pastedTexts(on: runner).count
        let phone = sessionFrame(
            target: "tmux:ordinary", payload: .text(TextPayload(text: String(repeating: "b", count: 2_001)))
        )
        #expect(!(await session.receive(phone)).frames.isEmpty)
        #expect(await pastedTexts(on: runner).count == before)
    }

    @Test func replyBridgeTargetsRefuseADispatchBeforeAnyTextAtAnySize() async throws {
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing))
        let registry = Registry()
        try await registry.register(
            TmuxReplyAdapter(terminal: TmuxAdapter(runner: runner, pollInterval: nil), targets: ["bridge"])
        )
        let session = try await session(registry, allowing: "tmux-reply:bridge", binding: bridgeBinding)
        // The bridge cannot grant a reply-binding lease, so the session refuses before HailHost.send: its
        // 8 KiB envelope cap is never what decides a dispatch.
        for size in [16, 1 << 20] {
            let request = LocalDispatchRequest(
                connection: UUID(), target: "tmux-reply:bridge", binding: bridgeBinding,
                text: String(repeating: "a", count: size)
            )
            await #expect(throws: LocalDispatchRefusal.deliveryRefused) { try await session.dispatch(request) }
        }
        #expect(await pastedTexts(on: runner).isEmpty)
    }
}
