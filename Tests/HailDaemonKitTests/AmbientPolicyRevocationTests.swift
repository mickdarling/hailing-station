import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

private enum AmbientPolicyWrite: String, CaseIterable, Sendable {
    case allow, deny, confirm, locked, rebound

    static let revocations: [Self] = [.deny, .confirm, .locked, .rebound]
}

private actor PolicyHandoffSleepGate {
    private var waiter: CheckedContinuation<Void, Never>?

    func sleep() async { await withCheckedContinuation { waiter = $0 } }

    func isWaiting() -> Bool { waiter != nil }

    func fire() {
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}

private struct AmbientPolicyRig {
    let adapter: FakeAdapter
    let store: InMemoryPolicyStore
    let host: HailHost
    let externalWriter: HailHost
    let session: HostSession
    let gate: AmbientAudioGate
    let sink: RecordingAmbientSink
    let stream: UUID

    static func make(allowB: Bool = true) async throws -> Self {
        let adapter = FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "a", binding: "binding-a"), AdapterTarget(name: "b", binding: "binding-b")
        ])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        if allowB { try policy.allow("tmux:b", binding: "binding-b", tier: .open) }
        let store = InMemoryPolicyStore(policy)
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
        if externally {
            // Observe the external write at the existing reload boundary, ahead of the audio hot path.
            let refreshed: Policy? = await host.refreshedPolicy()
            try #require(refreshed == store.stored)
        }
    }

    func pendingHandoff(_ sleep: PolicyHandoffSleepGate) async throws -> HostDeliveryOutcome {
        let frame: Frame = sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "synthetic")))
        let input: AuthorizedInput = try await authorizedInput(session, frame, device: "test")
        await sleep.sleep()
        return await session.deliver(input)
    }
}

/// #1028 FAIL-BEFORE: synthetic PCM only; no listener sockets, wall-clock deadlines or recorded content.
@Suite(.frozenGuardBudget) struct AmbientPolicyRevocationTests {
    @Test(arguments: AmbientPolicyWrite.revocations, [false, true])
    fileprivate func targetWritesRefuseNextSegmentAndSendTerminalStop(
        _ change: AmbientPolicyWrite, _ externally: Bool
    ) async throws {
        let rig = try await AmbientPolicyRig.make()
        try await rig.write(change, target: "tmux:a", externally: externally)
        let refused: HostSessionResult = await rig.segment(1)

        #expect(rig.sink.segments == [0])
        let endings: [AmbientStreamEndReason] = rig.sink.endings
        #expect(endings.count == 1)
        if let reason = endings.first {
            #expect(rig.sink.events.last == .ended(stream: rig.stream, reason: reason))
            #expect(reason != .final && reason != .idle && reason != .superseded)
        }
        let active: UUID? = await rig.gate.activeStream
        #expect(active == nil)
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.isEmpty)

        // Proposed wire reason: absent on this base. A bare token avoids the device's recoverable
        // `ambient stopped:` prefix; the device presentation will be "listening stopped: target permission changed".
        let expected: ControlPayload = .error(code: .notAllowed, message: "target_policy_changed")
        let controls: [ControlPayload] = refused.frames.compactMap { frame in
            guard case .control(let control) = frame.payload else { return nil }
            return control
        }
        #expect(controls == [expected])
        #expect(refused.frames.count == 1)
        #expect(refused.disposition == .keepOpen)
    }

    @Test(arguments: AmbientPolicyWrite.revocations, [false, true])
    fileprivate func preauthorizedHandoffIsRefusedAfterTargetWrite(
        _ change: AmbientPolicyWrite, _ externally: Bool
    ) async throws {
        let rig = try await AmbientPolicyRig.make()
        let sleep = PolicyHandoffSleepGate()
        let handoff = Task { try await rig.pendingHandoff(sleep) }
        await waitUntil { await sleep.isWaiting() }
        do {
            try await rig.write(change, target: "tmux:a", externally: externally)
        } catch {
            await sleep.fire()
            _ = try? await handoff.value
            throw error
        }
        await sleep.fire()
        let outcome: HostDeliveryOutcome = try await handoff.value
        let refused: Bool = switch outcome {
        case .refused, .confirmationRequired: true
        default: false
        }
        #expect(refused)
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test(arguments: AmbientPolicyWrite.allCases, [false, true])
    fileprivate func otherTargetWritesLeaveStreamAndHandoffAccepting(
        _ change: AmbientPolicyWrite, _ externally: Bool
    ) async throws {
        let rig = try await AmbientPolicyRig.make(allowB: change != .allow)
        let sleep = PolicyHandoffSleepGate()
        let handoff = Task { try await rig.pendingHandoff(sleep) }
        await waitUntil { await sleep.isWaiting() }
        do {
            try await rig.write(change, target: "tmux:b", externally: externally)
        } catch {
            await sleep.fire()
            _ = try? await handoff.value
            throw error
        }
        let next: HostSessionResult = await rig.segment(1)
        #expect(next.frames.isEmpty)
        #expect(next.disposition == .keepOpen)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        let active: UUID? = await rig.gate.activeStream
        #expect(active == rig.stream)
        await sleep.fire()
        let outcome: HostDeliveryOutcome = try await handoff.value
        #expect(outcome == .delivered(request: nil))
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.target == "a")
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async {
        while !(await predicate()) { await Task.yield() }
    }
}
