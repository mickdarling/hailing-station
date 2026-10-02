import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// `deliver` authorizes the exact input it hands off, so no in-module caller reaches `HailHost.send`
/// past an authorizer that would have refused the equivalent frame.
@Suite struct HostSessionDeliveryAuthorizationTests {
    private static let target = "tmux:reply"

    /// Permits negotiation and selection but denies every text frame: Codex's example on #197.
    private struct SelectOnlyAuthorizer: HostSessionAuthorizing {
        let capabilities = ["list_targets", "ping", "select_target"]
        func authorize(_ frame: Frame) async -> HostSessionAuthorization {
            guard case .control(let control) = frame.payload else { return .deny }
            switch control {
            case .hello, .ping, .listTargets, .select: return .allow
            default: return .deny
            }
        }
    }

    private func session(_ authorizer: any HostSessionAuthorizing) async throws -> (HostSession, FakeAdapter) {
        var policy = Policy()
        try policy.allow(Self.target, binding: "binding", tier: .open)
        let (host, adapter) = try await sessionHost(
            targets: [AdapterTarget(name: "reply", binding: "binding")], policy: policy
        )
        let session = HostSession(host: host, authorizer: authorizer, hostName: "mac-test")
        _ = await session.receive(helloFrame())
        return (session, adapter)
    }

    private func input() -> HostInput {
        HostInput(text: "synthetic input", target: Self.target, utteranceID: UUID(), device: "phone")
    }

    @Test func selectOnlyAuthorizerRefusesDirectDeliveryWithoutSending() async throws {
        let (session, adapter) = try await session(SelectOnlyAuthorizer())
        let selected = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        #expect(selected.frames.isEmpty)
        #expect(await session.selectedTarget == Self.target)
        #expect(await session.deliver(input()) == .unauthorized)
        // The frame path answers the same way, and neither path reached the adapter.
        let frame = sessionFrame(target: Self.target, payload: .text(TextPayload(text: "synthetic input")))
        #expect(try onlyControl(await session.receive(frame)) == .error(
            code: .unauthorized, message: "terminal action is not authorized"
        ))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func connectionProbeSessionRefusesDeliveryEvenWithAForcedSelection() async throws {
        let (session, adapter) = try await session(ConnectionProbeAuthorizer())
        await session.forceSelection(Self.target)
        #expect(await session.deliver(input()) == .unauthorized)
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func unnegotiatedSessionRefusesDelivery() async throws {
        var policy = Policy()
        try policy.allow(Self.target, binding: "binding", tier: .open)
        let (host, adapter) = try await sessionHost(
            targets: [AdapterTarget(name: "reply", binding: "binding")], policy: policy
        )
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        await session.forceSelection(Self.target)
        #expect(await session.deliver(input()) == .unauthorized)
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func personalTerminalAuthorizerStillDeliversLegacyInput() async throws {
        let (session, adapter) = try await session(PersonalTerminalAuthorizer())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        #expect(await session.deliver(input()) == .delivered(request: nil))
        #expect(await adapter.deliveries.count == 1)
    }
}

extension HostSession {
    /// Test-only: a selection no authorizer granted, to prove the delivery gate is not transitive on `select`.
    func forceSelection(_ target: String) { selectedTarget = target }
}
