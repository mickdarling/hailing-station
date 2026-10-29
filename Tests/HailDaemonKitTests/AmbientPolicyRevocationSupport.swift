import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

enum AmbientPolicyWrite: String, CaseIterable, Sendable {
    case allow, deny, confirm, locked, rebound

    static let revocations: [Self] = [.deny, .confirm, .locked, .rebound]
}

actor PolicyHandoffSleepGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var fired = false

    func sleep() async {
        if !fired { await withCheckedContinuation { waiter = $0 } }
    }

    func isWaiting() -> Bool { waiter != nil }

    func fire() {
        fired = true
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}

struct AmbientPolicyRig {
    let adapter: FakeAdapter
    let store: InMemoryPolicyStore
    let host: HailHost
    let externalWriter: HailHost
    let session: HostSession
    let gate: AmbientAudioGate
    let sink: RecordingAmbientSink
    let stream: UUID

    static func make(allowB: Bool = true, tier: Tier = .open,
                     beforeUpdate: @escaping @Sendable () -> Void = {}) async throws -> Self {
        let adapter = FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "a", binding: "binding-a"), AdapterTarget(name: "b", binding: "binding-b")
        ])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: tier)
        if allowB { try policy.allow("tmux:b", binding: "binding-b", tier: .open) }
        let store = InMemoryPolicyStore(policy, beforeUpdate: beforeUpdate)
        let host = try HailHost(registry: registry, store: store)
        let externalWriter = try HailHost(registry: registry, store: store)
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        let hello: HostSessionResult = await session.receive(helloFrame())
        guard case .hello = try onlyControl(hello) else { throw TestSupportError.expectedOneControl }
        let select: Frame = sessionFrame(payload: .control(.select(targetID: "tmux:a")))
        let selected: HostSessionResult = await session.receive(select)
        try #require(selected.frames.isEmpty)
        let rig = Self(adapter: adapter, store: store, host: host, externalWriter: externalWriter,
                       session: session, gate: gate, sink: sink, stream: UUID())
        let started: HostSessionResult = await rig.segment(0)
        try #require(started.frames.isEmpty)
        try #require(sink.segments == [0])
        try #require(sink.endings.isEmpty)
        return rig
    }

    func segment(_ sequence: Int) async -> HostSessionResult {
        let audio: AudioPayload = ambientSegment(stream: stream, sequence: sequence)
        return await session.receive(sessionFrame(target: "tmux:a", payload: .audio(audio)))
    }

    func write(_ change: AmbientPolicyWrite, target: String, externally: Bool) async throws {
        let writer: HailHost = externally ? externalWriter : host
        let before: Policy = store.stored
        switch change {
        case .allow:
            _ = try await writer.allow(target, tier: .open)
        case .deny:
            let changed: Bool = try await writer.deny(target)
            try #require(changed)
        case .confirm, .locked:
            let tier: Tier = change == .confirm ? .confirm : .locked
            let changed: Bool = try await writer.setTier(tier, for: target)
            try #require(changed)
        case .rebound:
            let reboundA: Bool = target == "tmux:a"
            await adapter.setTargets([
                AdapterTarget(name: "a", binding: reboundA ? "binding-a-new" : "binding-a"),
                AdapterTarget(name: "b", binding: reboundA ? "binding-b" : "binding-b-new")
            ])
            _ = try await writer.allow(target, tier: .open)
        }
        try #require(store.stored != before)
    }

    func pendingHandoff(_ sleep: PolicyHandoffSleepGate) async throws -> HostDeliveryOutcome {
        let frame: Frame = sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "synthetic")))
        let input: AuthorizedInput = try await authorizedInput(session, frame, device: "test")
        await sleep.sleep()
        return await session.deliver(input)
    }
}
