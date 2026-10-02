import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Legacy generic input retains no request record, so the captured selection itself must bind the handoff
/// for a caller that is not the peer's serialized receive loop (#188 local dispatch).
@Suite struct HostSessionLegacySelectionTests {
    private static let target = "tmux:reply"
    private static let other = "other:x"

    private func session(with adapter: any Adapter) async throws -> HostSession {
        let registry = Registry()
        try await registry.register(adapter)
        try await registry.register(FakeAdapter(kind: "other", targets: [AdapterTarget(name: "x", binding: "b")]))
        var policy = Policy()
        try policy.allow(Self.target, binding: "binding", tier: .open)
        try policy.allow(Self.other, binding: "b", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        return session
    }

    private func input() -> HostInput {
        HostInput(text: "synthetic input", target: Self.target, utteranceID: UUID(), device: "phone")
    }

    @Test func selectionChangeDuringTheListingRefusesBeforeAnyHandoff() async throws {
        let adapter = GatedListingFakeAdapter(AdapterTarget(name: "reply", binding: "binding"))
        let session = try await session(with: adapter)
        await adapter.gateNextListing()
        async let arrival: Void = adapter.nextListingArrival()
        let delivery = Task { await session.deliver(input()) }
        await arrival
        // The phone selects elsewhere while the input is parked in the registry listing.
        let selected = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.other))))
        #expect(selected.frames.isEmpty)
        await adapter.releaseListing()
        #expect(await delivery.value == .selectionChanged)
        #expect(await adapter.deliveries.isEmpty)
        // The frame path reports the same refusal the contextual path already used for this case.
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        await adapter.gateNextListing()
        async let secondArrival: Void = adapter.nextListingArrival()
        let frame = sessionFrame(target: Self.target, payload: .text(TextPayload(text: "synthetic input")))
        let routed = Task { await session.receive(frame) }
        await secondArrival
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.other))))
        await adapter.releaseListing()
        let control = try onlyControl(await routed.value)
        #expect(control == .error(code: .notAllowed, message: "request destination changed"))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func selectionChangeDuringTheHandoffIsReportedAsUnowned() async throws {
        let adapter = GatedFakeAdapter(AdapterTarget(name: "reply", binding: "binding"))
        let session = try await session(with: adapter)
        async let arrival: Void = adapter.nextArrival()
        let delivery = Task { await session.deliver(input()) }
        await arrival
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.other))))
        await adapter.release()
        // The text had already reached the adapter; the outcome says so without claiming a current recipient.
        #expect(await delivery.value == .unowned("request destination changed"))
        #expect(await adapter.deliveries == ["synthetic input"])
    }

    @Test func sessionClosureDuringTheHandoffIsReportedAsUnowned() async throws {
        let adapter = GatedFakeAdapter(AdapterTarget(name: "reply", binding: "binding"))
        let session = try await session(with: adapter)
        async let arrival: Void = adapter.nextArrival()
        let delivery = Task { await session.deliver(input()) }
        await arrival
        // A protocol closure (version mismatch) ends the session while the text is inside the adapter.
        _ = await session.receive(sessionFrame(version: 2, payload: .control(.ping(nonce: "x"))))
        await adapter.release()
        #expect(await delivery.value == .unowned("request destination changed"))
        #expect(await session.state == .closed)
    }

    @Test func unchangedSelectionDeliversLegacyInputWithoutARequest() async throws {
        let adapter = GatedFakeAdapter(AdapterTarget(name: "reply", binding: "binding"))
        let session = try await session(with: adapter)
        async let arrival: Void = adapter.nextArrival()
        let delivery = Task { await session.deliver(input()) }
        await arrival
        await adapter.release()
        #expect(await delivery.value == .delivered(request: nil))
    }
}
