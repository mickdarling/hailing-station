import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct PersonalTerminalSessionTests {
    @Test func selectedFinalTextIsDeliveredAndPartialTextIsRefused() async throws {
        let target = AdapterTarget(name: "a", binding: "binding-a")
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        let (host, adapter) = try await sessionHost(targets: [target], policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())

        let hello = await session.receive(helloFrame())
        guard case .hello(let info) = try onlyControl(hello) else {
            Issue.record("expected hello")
            return
        }
        #expect(info.capabilities.contains("send_text"))

        #expect((await session.receive(sessionFrame(
            payload: .control(.select(targetID: "tmux:a"))
        ))).frames.isEmpty)
        #expect((await session.receive(sessionFrame(
            target: "tmux:a", payload: .text(TextPayload(text: "echo hello", isFinal: true))
        ))).frames.isEmpty)
        #expect(await adapter.deliveries.map(\.text) == ["echo hello"])

        let partial = await session.receive(sessionFrame(
            target: "tmux:a", payload: .text(TextPayload(text: "echo", isFinal: false))
        ))
        guard case .error(let code, _) = try onlyControl(partial) else {
            Issue.record("expected refusal")
            return
        }
        #expect(code == .unauthorized)
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func deliveryFailsClosedWithoutSelectionOrOpenTier() async throws {
        let target = AdapterTarget(name: "a", binding: "binding-a")
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .confirm)
        let (host, adapter) = try await sessionHost(targets: [target], policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())

        let unselected = await session.receive(sessionFrame(
            target: "tmux:a", payload: .text(TextPayload(text: "echo hello"))
        ))
        guard case .error(let unselectedCode, _) = try onlyControl(unselected) else {
            Issue.record("expected selection refusal")
            return
        }
        #expect(unselectedCode == .notAllowed)

        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        let confirmation = await session.receive(sessionFrame(
            target: "tmux:a", payload: .text(TextPayload(text: "echo hello"))
        ))
        guard case .error(let confirmationCode, _) = try onlyControl(confirmation) else {
            Issue.record("expected confirmation refusal")
            return
        }
        #expect(confirmationCode == .notAllowed)
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func escapeRequiresSelectionAndUsesTheAdapterControlPath() async throws {
        let target = AdapterTarget(name: "a", binding: "binding-a")
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .confirm)
        let (host, adapter) = try await sessionHost(targets: [target], policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())

        let beforeSelection = await session.receive(sessionFrame(
            payload: .control(.escape(targetID: "tmux:a"))
        ))
        guard case .error(let code, _) = try onlyControl(beforeSelection) else {
            Issue.record("expected selection refusal")
            return
        }
        #expect(code == .notAllowed)

        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        #expect((await session.receive(sessionFrame(
            payload: .control(.escape(targetID: "tmux:a"))
        ))).frames.isEmpty)
        #expect(await adapter.escapes == ["a"])
    }
}
